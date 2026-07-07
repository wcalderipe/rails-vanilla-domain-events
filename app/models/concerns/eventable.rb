module Eventable
  extend ActiveSupport::Concern

  included do
    has_many :events, as: :eventable
  end

  # Runs in the caller's transaction: the fact commits atomically with the
  # state change it records. This is the outbox write.
  #
  # idempotence_key gives a free-standing fact its publication identity:
  # republishing with the same key is a no-op that returns the recorded
  # fact. Insert-first (create! resolved by the unique partial index), not
  # check-then-act, for the same TOCTOU reason the consumers dedupe with
  # unique indexes. Facts anchored in a unique state record do not need a
  # key: their transaction already cannot commit twice.
  #
  # Recovery reads through Event, not the `events` association: the unique index
  # is GLOBAL (any idempotence_key is unique across every eventable), so the key
  # is a free-standing identity, not a per-record one. A scoped `events.find_by!`
  # would raise RecordNotFound when the same key was first recorded against a
  # different eventable — the exact case a global key exists to collapse.
  def publish_event(action, idempotence_key: nil, **payload)
    events.create!(action:, payload:, idempotence_key:)
  rescue ActiveRecord::RecordNotUnique
    raise if idempotence_key.nil?
    Event.find_by!(idempotence_key:)
  end
end
