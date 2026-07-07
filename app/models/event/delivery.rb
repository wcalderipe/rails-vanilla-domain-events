class Event::Delivery < ApplicationRecord
  MAX_ATTEMPTS = 5

  # A pending delivery untouched for this long has lost its job (crash after
  # enqueue, exhausted retries, parked failed execution) and is redelivery-eligible.
  REDELIVER_AFTER = 5.minutes

  belongs_to :event

  scope :pending, -> { where(delivered_at: nil, failed_at: nil) }
  scope :stale, -> { pending.where(updated_at: ..REDELIVER_AFTER.ago) }

  # Tier 2 of the relay: re-drives deliveries whose effect never landed.
  # Exhausting MAX_ATTEMPTS is a terminal transition, not another loop:
  # the delivery fails and the failure is reported, so a permanently broken
  # subscriber pages a human instead of retrying forever.
  def self.redeliver_stale
    stale.find_each do |delivery|
      if delivery.attempts >= MAX_ATTEMPTS
        delivery.mark_failed(error: "redelivery attempts exhausted")
      else
        delivery.deliver_later
      end
    end
  end

  def deliver_later
    increment!(:attempts)
    subscriber.constantize.perform_later(self)
  end

  # The subscriber's effect and its acknowledgment commit atomically. A crash
  # after the effect but before the ack causes a redelivery, which the
  # terminal guard (or the consumer's own idempotency) absorbs.
  def fulfill
    return if terminal?

    transaction do
      yield event
      update!(delivered_at: Time.current)
    end
  end

  def mark_failed(error:)
    update!(failed_at: Time.current, error: error)
    Rails.error.report(RuntimeError.new("event delivery failed: #{error}"),
                       context: { delivery_id: id, event_id: event_id, subscriber: subscriber })
  end

  def terminal? = delivered_at.present? || failed_at.present?
  def delivered? = delivered_at.present?
  def failed? = failed_at.present?
end
