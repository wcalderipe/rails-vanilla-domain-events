class Event < ApplicationRecord
  # An undispatched event older than this has clearly lost its post-commit
  # fanout (crashed process, lost enqueue) and is eligible for relay.
  RELAY_AFTER = 1.minute

  # Most events a single relay tick will touch, across both sweeps. This
  # caps how long a tick can run, which matters for the semaphore in
  # Event::RelayJob: that guard is a fixed-TTL lease, not a lifetime lock,
  # so a tick that ran longer than the lease would lose exclusivity and
  # overlap the next tick. A large backlog just drains over several short
  # ticks; anything left over is picked up on the next one (the
  # stranded/stale scopes simply re-select it).
  RELAY_BATCH = 500

  # How long the log remembers. The window is a business decision (audit
  # needs, privacy: payloads carry PII); the mechanism only enforces it.
  RETENTION = 90.days

  belongs_to :eventable, polymorphic: true
  has_many :deliveries, class_name: "Event::Delivery", dependent: :destroy

  # Append-only on the domain side: the fact itself never changes.
  # dispatched_at is outbox bookkeeping, not part of the fact, so it stays
  # writable.
  attr_readonly :eventable_id, :eventable_type, :action, :payload, :idempotence_key

  # Test/demo seam: turning this off simulates a crash between the commit
  # and the fanout.
  class_attribute :dispatch_after_create, default: true

  scope :chronologically, -> { order(:created_at, :id) }
  scope :dispatched, -> { where.not(dispatched_at: nil) }
  scope :stranded, -> { where(dispatched_at: nil).where(created_at: ..RELAY_AFTER.ago) }

  # Prunable = old enough AND owing nothing: dispatched (an undispatched
  # event still owes its whole fanout, however old) with no pending delivery
  # (a pending delivery is work the relay may still re-drive; deleting the
  # event would strand its job into chapter 2's discard_on, the silent drop
  # the prune test documents). Terminal deliveries and zero-subscriber
  # events are memory, not work, so age alone decides.
  scope :prunable, -> {
    dispatched
      .where(created_at: ..RETENTION.ago)
      .where.not(id: Event::Delivery.pending.select(:event_id))
  }

  after_create_commit :dispatch, if: :dispatch_after_create

  class << self
    # The subscriber is registered as a string, not a constant, for the
    # same reason associations use class_name: as a string — dispatch
    # resolves it with constantize at call time, so it always hits the
    # currently loaded class across dev reloads (a captured constant would
    # go stale, and a Set would build up one dead class object per reload).
    # Calling constantize here too means a typo fails at registration, not
    # on the first dispatch.
    def subscribe(action, job_class_name)
      job_class_name.constantize
      subscriptions[action] << job_class_name
    end

    def subscribers_for(action) = subscriptions[action].to_a

    def subscriptions
      @subscriptions ||= Hash.new { |hash, key| hash[key] = Set.new }
    end

    # The message relay: re-dispatches events whose fanout was lost, so
    # delivery is at-least-once. Runs on a schedule via Event::RelayJob.
    # Errors are rescued per item so one bad event doesn't abort the sweep
    # for the rest (a reported, still-stranded event stays visible to the
    # next tick and to oldest_stranded_age). Returns the count swept, used
    # as the relay's liveness signal.
    def relay_stranded
      swept = 0

      # Bounded and oldest-first: at most RELAY_BATCH per tick (see the
      # constant above), draining the longest-stranded events first.
      stranded.chronologically.limit(RELAY_BATCH).each do |event|
        event.dispatch
        swept += 1
      rescue StandardError => error
        Rails.error.report(error, context: { event_id: event.id, action: event.action })
      end

      swept
    end

    # Age, in seconds, of the oldest event still waiting for its fanout;
    # nil if nothing is waiting. Used as the relay's health check — if this
    # grows past the sweep interval, the relay isn't running.
    def oldest_stranded_age
      oldest = where(dispatched_at: nil).minimum(:created_at)
      oldest && Time.current - oldest
    end

    # Deletes prunable events in batches, deliveries first (the foreign key
    # demands it). delete_all on purpose: neither model has destroy
    # callbacks, so skipping them changes nothing today, and a prune that
    # instantiated ninety days of rows to fire no-op callbacks would be
    # ceremony. The dependent: :destroy on the association stays for one-off
    # console destroys. Returns the pruned count for the liveness signal.
    def prune(batch_size: 500)
      pruned = 0

      loop do
        batch_ids = prunable.limit(batch_size).pluck(:id)
        break if batch_ids.empty?

        transaction do
          Event::Delivery.where(event_id: batch_ids).delete_all
          pruned += where(id: batch_ids).delete_all
        end
      end

      pruned
    end
  end

  # Upsert one delivery per subscriber, enqueue each, then mark the fanout
  # done. dispatched_at means "delivery rows exist and the initial enqueue
  # was attempted," not that each delivery actually succeeded — that's
  # tracked on the delivery itself. A crash mid-fanout leaves dispatched_at
  # nil, so the relay redoes the fanout; create_or_find_by! (insert-first,
  # resolved by the unique index) makes that safe to repeat per delivery,
  # and consumers stay idempotent since delivery is at-least-once anyway.
  def dispatch
    return if dispatched?

    self.class.subscribers_for(action).each do |job_class_name|
      delivery = Event::Delivery.create_or_find_by!(event: self, subscriber: job_class_name)
      delivery.deliver_later unless delivery.terminal?
    end
    update!(dispatched_at: Time.current)
  end

  def dispatched? = dispatched_at.present?
end
