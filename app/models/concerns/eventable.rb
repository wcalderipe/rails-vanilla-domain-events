module Eventable
  extend ActiveSupport::Concern

  included do
    has_many :events, as: :eventable
  end

  # Runs in the caller's transaction, so the fact commits atomically with the
  # state change it records. This is the outbox write.
  #
  # idempotence_key is the fact's publication identity: republishing with the
  # same key is a no-op that returns the existing fact. We insert first (via
  # create!, backed by a unique partial index) instead of checking then
  # acting, for the same race-condition reason consumers dedupe with unique
  # indexes. Facts tied to a unique state record don't need a key, since
  # their transaction already can't commit twice.
  #
  # Recovery reads through Event, not the `events` association, because the
  # unique index is global: any idempotence_key is unique across every
  # eventable, so the key is a free-standing identity, not scoped to one
  # record. A scoped `events.find_by!` would raise RecordNotFound if the same
  # key was first recorded against a different eventable — exactly the case
  # a global key exists to handle.
  #
  # The guarded insert runs in a savepoint (requires_new). On SQLite this
  # changes nothing observable. On PostgreSQL a failed statement poisons the
  # surrounding transaction, and rescuing RecordNotUnique without a savepoint
  # would leave the caller's transaction unusable (chapter 9). Same pattern
  # everywhere we do a guarded insert.
  def publish_event(action, idempotence_key: nil, **payload)
    Event.transaction(requires_new: true) do
      events.create!(action:, payload:, idempotence_key:)
    end
  rescue ActiveRecord::RecordNotUnique
    raise if idempotence_key.nil?
    Event.find_by!(idempotence_key:)
  end
end
