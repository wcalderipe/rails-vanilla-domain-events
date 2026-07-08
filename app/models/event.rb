class Event < ApplicationRecord
  # An event still undispatched after this long has lost its post-commit
  # fanout (crashed process, lost enqueue) and is eligible for the relay
  # to retry.
  RELAY_AFTER = 1.minute

  # Max events one relay tick processes, across both recovery passes. This
  # bounds tick duration, which matters because Event::RelayJob's lock is a
  # fixed-TTL lease, not a permanent hold — a tick that ran longer than the
  # lease could lose exclusivity and overlap the next tick. A large backlog
  # just drains over several ticks; whatever's left gets picked up next time,
  # since the stranded/stale scopes re-select it.
  RELAY_BATCH = 500

  # How long events are kept. The window itself is a business decision
  # (audit needs vs. privacy, since payloads carry PII) — this constant
  # just enforces it.
  RETENTION = 90.days

  belongs_to :eventable, polymorphic: true
  has_many :deliveries, class_name: "Event::Delivery", dependent: :destroy

  # The domain fact is append-only and never changes. dispatched_at is
  # outbox bookkeeping, not part of the fact, so it's left writable.
  attr_readonly :eventable_id, :eventable_type, :action, :payload, :idempotence_key

  # Test/demo seam — turning this off simulates a crash between the
  # commit and the fanout.
  class_attribute :dispatch_after_create, default: true

  scope :chronologically, -> { order(:created_at, :id) }
  scope :dispatched, -> { where.not(dispatched_at: nil) }
  scope :stranded, -> { where(dispatched_at: nil).where(created_at: ..RELAY_AFTER.ago) }

  # Prunable means old enough and owing nothing:
  #   - dispatched — an undispatched event still owes its whole fanout,
  #     no matter how old
  #   - no pending delivery — a pending delivery is work the relay might
  #     still retry; deleting the event would strand that job into its
  #     discard_on handler, which silently drops it (as the prune test
  #     documents)
  # Events with only terminal deliveries, or no subscribers, are just
  # history, so once they're old enough, age alone makes them prunable.
  scope :prunable, -> {
    dispatched
      .where(created_at: ..RETENTION.ago)
      .where.not(id: Event::Delivery.pending.select(:event_id))
  }

  after_create_commit :dispatch, if: :dispatch_after_create

  class << self
    # Subscribers are registered by class name string, not constant — the
    # same reason associations use class_name: as a string. dispatch
    # resolves the string with constantize at call time, so it always hits
    # the currently loaded class across dev reloads (a captured constant
    # would go stale, and the Set would fill up with dead class objects).
    # The eager constantize call below validates the string immediately,
    # so a typo fails at registration instead of on first dispatch.
    def subscribe(action, job_class_name)
      job_class_name.constantize
      subscriptions[action] << job_class_name
    end

    def subscribers_for(action) = subscriptions[action].to_a

    def subscriptions
      @subscriptions ||= Hash.new { |hash, key| hash[key] = Set.new }
    end

    # The message relay: re-dispatches events whose fanout was lost,
    # making delivery at-least-once. Runs on a schedule via
    # Event::RelayJob. Errors are rescued per event so one bad event
    # doesn't abort the whole sweep — it stays stranded and visible to
    # the next tick and to oldest_stranded_age. Returns the count swept,
    # used as the relay's liveness signal.
    def relay_stranded
      swept = 0

      # Bounded and oldest-first: at most RELAY_BATCH events per tick
      # (see the constant above for why), draining the longest-stranded
      # ones first.
      stranded.chronologically.limit(RELAY_BATCH).each do |event|
        event.dispatch
        swept += 1
      rescue StandardError => error
        Rails.error.report(error, context: { event_id: event.id, action: event.action })
      end

      swept
    end

    # Age in seconds of the oldest event still waiting for its fanout, or
    # nil if none are waiting. Used as the relay's health check — if this
    # exceeds the sweep interval, the relay isn't running.
    def oldest_stranded_age
      oldest = where(dispatched_at: nil).minimum(:created_at)
      oldest && Time.current - oldest
    end

    # Deletes prunable events in batches, deliveries first since the
    # foreign key requires it. Uses delete_all on purpose: neither model
    # has destroy callbacks, so skipping them changes nothing, and
    # instantiating 90 days of rows just to run no-op callbacks would be
    # wasteful. The dependent: :destroy on the association is kept for
    # one-off console destroys. Returns the pruned count, used as the
    # liveness signal.
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

  # Upserts one delivery per subscriber, enqueues each, then marks the
  # fanout done. dispatched_at means "delivery rows exist and the initial
  # enqueue was attempted" — whether each delivery actually landed is
  # tracked separately. If a crash happens mid-fanout, dispatched_at stays
  # nil and the relay redoes the fanout; create_or_find_by! (insert-first,
  # resolved by a unique index) makes that safe to repeat per delivery,
  # and consumers still need to be idempotent since delivery is
  # at-least-once.
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
