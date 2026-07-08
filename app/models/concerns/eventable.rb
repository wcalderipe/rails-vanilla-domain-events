module Eventable
  extend ActiveSupport::Concern

  included do
    has_many :events, as: :eventable
  end

  # Runs in the caller's transaction, so the fact commits atomically with
  # the state change it records. This is the outbox write.
  def publish_event(action, **payload)
    events.create!(action:, payload:)
  end
end
