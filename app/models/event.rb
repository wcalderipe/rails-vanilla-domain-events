class Event < ApplicationRecord
  # A still-undispatched event older than this has clearly lost its
  # post-commit fanout (crashed process, lost enqueue) and is relay-eligible.
  RELAY_AFTER = 1.minute

  belongs_to :eventable, polymorphic: true

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
    # The subscriber is registered as a string, not a constant, for the same
    # reason associations take class_name: as a string: dispatch resolves it
    # with constantize at call time, so it always hits the currently loaded
    # class across dev reloads (a captured constant would go stale, and Set
    # would accumulate one dead class object per reload). The eager
    # constantize below keeps the string honest: a typo explodes here, at
    # registration, not on the first dispatch.
    def subscribe(action, job_class_name)
      job_class_name.constantize
      subscriptions[action] << job_class_name
    end

    def subscribers_for(action) = subscriptions[action].to_a

    def subscriptions
      @subscriptions ||= Hash.new { |hash, key| hash[key] = Set.new }
    end

    # The Message Relay: re-dispatches events whose fanout was lost, making
    # delivery at-least-once. Run on a schedule by Event::RelayJob.
    def relay_stranded
      stranded.find_each(&:dispatch)
    end
  end

  # Enqueue one job per subscriber, then mark the fanout done. A crash
  # mid-fanout leaves dispatched_at nil and the relay redoes the WHOLE
  # fanout, so a subscriber can see the same event twice: consumers must
  # be idempotent.
  def dispatch
    return if dispatched?

    self.class.subscribers_for(action).each do |job_class_name|
      job_class_name.constantize.perform_later(self)
    end
    update!(dispatched_at: Time.current)
  end

  def dispatched? = dispatched_at.present?
end
