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
  # Recovery reads through Event, not the `events` association: the unique index
  # is GLOBAL (any idempotence_key is unique across every eventable), so the key
  # is a free-standing identity, not a per-record one. A scoped `events.find_by!`
  # would raise RecordNotFound when the same key was first recorded against a
  # different eventable — the exact case a global key exists to collapse.
  #
  # The guarded insert runs in a savepoint (requires_new). On SQLite this
  # changes nothing observable; on PostgreSQL a failed statement poisons the
  # enclosing transaction, and rescuing RecordNotUnique without a savepoint
  # would leave the caller's transaction unusable (chapter 9). Same pattern
  # at every guarded-insert site.
  def publish_event(action, idempotence_key: nil, **payload)
    Event.transaction(requires_new: true) do
      events.create!(action:, payload:, idempotence_key:)
    end
  rescue ActiveRecord::RecordNotUnique
    raise if idempotence_key.nil?
    Event.find_by!(idempotence_key:)
  end
end
