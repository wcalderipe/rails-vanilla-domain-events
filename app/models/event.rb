class Event < ApplicationRecord
  # A still-undispatched event older than this has lost its post-commit
  # fanout (crashed process, lost enqueue) and is eligible for the relay.
  RELAY_AFTER = 1.minute

  belongs_to :eventable, polymorphic: true
  has_many :deliveries, class_name: "Event::Delivery", dependent: :destroy

  # Append-only on the domain side: the fact never changes. dispatched_at
  # is outbox bookkeeping, not part of the fact, so it stays writable.
  attr_readonly :eventable_id, :eventable_type, :action, :payload

  # Test/demo seam: turning this off simulates a crash between the commit
  # and the fanout.
  class_attribute :dispatch_after_create, default: true

  scope :chronologically, -> { order(:created_at, :id) }
  scope :dispatched, -> { where.not(dispatched_at: nil) }
  scope :stranded, -> { where(dispatched_at: nil).where(created_at: ..RELAY_AFTER.ago) }

  after_create_commit :dispatch, if: :dispatch_after_create

  class << self
    # The subscriber is stored as a string, not a constant, for the same
    # reason associations use class_name: as a string — dispatch resolves
    # it with constantize at call time, so it always hits the currently
    # loaded class across dev reloads (a captured constant would go stale,
    # and a Set would accumulate one dead class object per reload). The
    # eager constantize below catches a typo here, at registration, rather
    # than on the first dispatch.
    def subscribe(action, job_class_name)
      job_class_name.constantize
      subscriptions[action] << job_class_name
    end

    def subscribers_for(action) = subscriptions[action].to_a

    def subscriptions
      @subscriptions ||= Hash.new { |hash, key| hash[key] = Set.new }
    end

    # The message relay: re-dispatches events whose fanout was lost, so
    # delivery is at-least-once. Run on a schedule by Event::RelayJob.
    def relay_stranded
      stranded.find_each(&:dispatch)
    end
  end

  # Upsert one delivery per subscriber, enqueue each, then mark the fanout
  # done. dispatched_at now means "delivery rows exist and the initial
  # enqueue was attempted"; whether each effect landed is the delivery's
  # own record. A crash mid-fanout leaves dispatched_at nil and the relay
  # redoes the fanout; create_or_find_by! (insert-first, resolved by the
  # unique index) makes that re-run idempotent per delivery, and consumers
  # stay idempotent because delivery is still at-least-once.
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
