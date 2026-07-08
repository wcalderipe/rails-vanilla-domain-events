module Eventable
  extend ActiveSupport::Concern

  included do
    has_many :events, as: :eventable
  end

  # Runs in the caller's transaction, so the fact commits atomically with
  # the state change it records. This is the outbox write.
  #
  # idempotence_key gives a fact its own publication identity: republishing
  # with the same key is a no-op that returns the existing fact. We insert
  # first (create!, relying on the unique partial index) instead of
  # checking then acting, for the same race-condition reason consumers
  # dedupe with unique indexes. A fact tied to a unique state record
  # doesn't need a key, since its transaction can't commit twice anyway.
  #
  # Recovery looks up through Event, not the `events` association, because
  # the unique index is GLOBAL: any idempotence_key is unique across every
  # eventable, not just this one. A scoped `events.find_by!` would raise
  # RecordNotFound if the same key was first recorded on a different
  # eventable — exactly the case a global key exists to handle.
  def publish_event(action, idempotence_key: nil, **payload)
    events.create!(action:, payload:, idempotence_key:)
  rescue ActiveRecord::RecordNotUnique
    raise if idempotence_key.nil?
    Event.find_by!(idempotence_key:)
  end
end
