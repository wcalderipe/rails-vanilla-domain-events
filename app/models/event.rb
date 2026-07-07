class Event < ApplicationRecord
  # An event still undispatched after this long has lost its post-commit
  # fanout (crashed process, lost enqueue) and is eligible for the relay.
  RELAY_AFTER = 1.minute

  belongs_to :eventable, polymorphic: true
  has_many :deliveries, class_name: "Event::Delivery", dependent: :destroy

  # Append-only on the domain side: the fact never changes. dispatched_at is
  # outbox bookkeeping, not part of the fact, so it stays writable.
  attr_readonly :eventable_id, :eventable_type, :action, :payload

  # Internal seam for tests and the demo: turning this off simulates the
  # crash between the commit and the fanout.
  class_attribute :dispatch_after_create, default: true

  scope :chronologically, -> { order(:created_at, :id) }
  scope :dispatched, -> { where.not(dispatched_at: nil) }
  scope :stranded, -> { where(dispatched_at: nil).where(created_at: ..RELAY_AFTER.ago) }

  after_create_commit :dispatch, if: :dispatch_after_create

  class << self
    # Subscribers are registered by class name string, not constant — the
    # same reason associations use class_name:. dispatch resolves the string
    # with constantize at call time, so it always hits the current class
    # across dev reloads (a captured constant would go stale, and Set would
    # pile up dead class objects on every reload). The eager constantize
    # below catches a typo at registration instead of on the first dispatch.
    def subscribe(action, job_class_name)
      job_class_name.constantize
      subscriptions[action] << job_class_name
    end

    def subscribers_for(action) = subscriptions[action].to_a

    def subscriptions
      @subscriptions ||= Hash.new { |hash, key| hash[key] = Set.new }
    end

    # The Message Relay: re-dispatches events whose fanout was lost, making
    # delivery at-least-once. Run on a schedule by Event::RelayJob. Rescued
    # per item: one poison event must not abort the sweep for everything
    # behind it (a reported, still-stranded event stays visible to the next
    # tick and to oldest_stranded_age). Returns the swept count for the
    # relay's liveness signal.
    def relay_stranded
      swept = 0

      stranded.find_each do |event|
        event.dispatch
        swept += 1
      rescue StandardError => error
        Rails.error.report(error, context: { event_id: event.id, action: event.action })
      end

      swept
    end

    # Age of the oldest event still waiting for its fanout, in seconds; nil
    # when nothing is waiting. The relay's health reading: if this grows past
    # the sweep interval, the guard is asleep.
    def oldest_stranded_age
      oldest = where(dispatched_at: nil).minimum(:created_at)
      oldest && Time.current - oldest
    end
  end

  # Upsert one delivery per subscriber, enqueue each, then mark the fanout
  # done. dispatched_at means "delivery rows exist and enqueue was
  # attempted" — whether the effect actually landed is tracked on the
  # delivery itself. A crash mid-fanout leaves dispatched_at nil, so the
  # relay redoes the fanout; create_or_find_by! (insert-first, resolved via
  # the unique index) makes that re-run idempotent per delivery, and
  # delivery stays at-least-once for consumers.
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
