# The customer-notification effect of order.paid. Idempotent by natural key:
# the unique index on order_id makes a replayed event a no-op, so
# at-least-once delivery still confirms exactly once.
class Order::Confirmation < ApplicationRecord
  belongs_to :order, touch: true

  # Recording the confirmation and sending the email are one unit: the email
  # only goes out on the first successful create, so a redelivery (the relay
  # re-sending the same event) never re-mails. The insert and the send share
  # a transaction, so a transient mail failure rolls the row back too — the
  # order isn't "confirmed" until the mail actually went out, and the job's
  # retry_on re-runs the whole thing cleanly.
  #
  # The tradeoff, stated plainly:
  #   - the email is at-least-once, not exactly-once. If deliver_now
  #     succeeds but the commit right after it fails, the retry re-sends.
  #   - deliver_now is an IO call held open inside a DB transaction, so a
  #     slow mail server holds the row's write locks. Acceptable at this
  #     domain's scale, but a real system would move the send behind its own
  #     outbox instead.
  #
  # requires_new: the savepoint that keeps the RecordNotUnique rescue safe on
  # PostgreSQL (chapter 9).
  def self.record(event)
    order = event.eventable

    transaction(requires_new: true) do
      confirmation = create!(order:)
      OrderMailer.confirmation(order).deliver_now
      confirmation
    end
  rescue ActiveRecord::RecordNotUnique
    find_by(order_id: event.eventable_id)
  end
end
