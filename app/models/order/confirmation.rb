# The customer-notification effect of order.paid. Idempotent by natural
# key: the unique index on order_id makes a replayed event a no-op, so
# at-least-once delivery confirms exactly once.
class Order::Confirmation < ApplicationRecord
  belongs_to :order, touch: true

  # Recording the confirmation and sending the email are one unit: the email
  # goes out only on the FIRST successful create, so a redelivery (the relay
  # re-driving the same event) never re-mails. The insert and the send share a
  # transaction, so a transient mail failure rolls the row back with it — the
  # order is not "confirmed" until the mail actually left, and the job's
  # retry_on re-runs the whole unit cleanly.
  #
  # The tradeoff, stated plainly: the email is at-least-once, not exactly-once.
  # If deliver_now succeeds but the commit right after it fails, the retry
  # re-sends. And deliver_now is IO held open inside a DB transaction, so a slow
  # mail server holds the row's write locks; acceptable at this domain's scale,
  # and the honest boundary where a real system would move the send behind its
  # own outbox.
  def self.record(event)
    order = event.eventable

    transaction do
      confirmation = create!(order:)
      OrderMailer.confirmation(order).deliver_now
      confirmation
    end
  rescue ActiveRecord::RecordNotUnique
    find_by(order_id: event.eventable_id)
  end
end
