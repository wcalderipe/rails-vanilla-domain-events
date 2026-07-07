class Event < ApplicationRecord
  # An undispatched event older than this has clearly lost its post-commit
  # fanout (crashed process, lost enqueue) and is eligible for the relay.
  RELAY_AFTER = 1.minute

  # Max events a single relay tick will touch, across both recovery passes.
  # This caps how long a tick can run, which matters for the semaphore in
  # Event::RelayJob: that guard is a fixed-TTL lease, not a lifetime lock, so
  # a tick that outran the lease would lose its exclusivity mid-run and
  # overlap the next tick. A backlog drains over several short ticks instead;
  # anything left over gets picked up next time (the stranded/stale scopes
  # just re-select it).
  RELAY_BATCH = 500

  belongs_to :eventable, polymorphic: true
  has_many :deliveries, class_name: "Event::Delivery", dependent: :destroy

  # Append-only on the domain side: the fact never changes. dispatched_at is
  # outbox bookkeeping, not part of the fact, so it stays writable.
  attr_readonly :eventable_id, :eventable_type, :action, :payload, :idempotence_key

  # Test/demo seam: turning this off simulates a crash between the commit
  # and the fanout.
  class_attribute :dispatch_after_create, default: true

  scope :chronologically, -> { order(:created_at, :id) }
  scope :dispatched, -> { where.not(dispatched_at: nil) }
  scope :stranded, -> { where(dispatched_at: nil).where(created_at: ..RELAY_AFTER.ago) }

  after_create_commit :dispatch, if: :dispatch_after_create

  class << self
    # The subscriber is registered as a string, the same reason associations
    # use class_name: as a string. dispatch resolves it with constantize at
    # call time, so it always hits the currently loaded class across dev
    # reloads (a captured constant would go stale, and a Set would accumulate
    # one dead class object per reload). The eager constantize below keeps
    # the string honest: a typo fails here, at registration, not on the
    # first dispatch.
    def subscribe(action, job_class_name)
      job_class_name.constantize
      subscriptions[action] << job_class_name
    end

    def subscribers_for(action) = subscriptions[action].to_a

    def subscriptions
      @subscriptions ||= Hash.new { |hash, key| hash[key] = Set.new }
    end

    # Pass 1 of the relay (see Event::RelayJob): re-dispatches events whose
    # fanout was lost, making delivery at-least-once. Run on a schedule by
    # Event::RelayJob. Rescued per item, so one bad event can't abort the
    # sweep for everything behind it — a reported, still-stranded event
    # stays visible to the next tick and to oldest_stranded_age. Returns the
    # swept count for the relay's liveness signal.
    def relay_stranded
      swept = 0

      # Bounded and oldest-first: at most RELAY_BATCH per tick (see the
      # constant for why the bound matters), draining the longest-stranded
      # events first.
      stranded.chronologically.limit(RELAY_BATCH).each do |event|
        event.dispatch
        swept += 1
      rescue StandardError => error
        Rails.error.report(error, context: { event_id: event.id, action: event.action })
      end

      swept
    end

    # Age of the oldest event still waiting for its fanout, in seconds; nil
    # if nothing is waiting. This is the relay's health reading: if it grows
    # past the sweep interval, the guard is asleep.
    def oldest_stranded_age
      oldest = where(dispatched_at: nil).minimum(:created_at)
      oldest && Time.current - oldest
    end
  end

  # Upsert one delivery per subscriber, enqueue each, then mark the fanout
  # done. dispatched_at now means "delivery rows exist and the initial
  # enqueue was attempted"; whether each effect actually landed is tracked on
  # the delivery itself. A crash mid-fanout leaves dispatched_at nil, so the
  # relay redoes the fanout; create_or_find_by! (insert-first, resolved by
  # the unique index) makes that re-run idempotent per delivery, and
  # consumers stay idempotent since delivery is still at-least-once.
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
