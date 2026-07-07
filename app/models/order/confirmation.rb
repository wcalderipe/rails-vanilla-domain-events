# Handles the customer-notification effect of order.paid. Idempotent by
# natural key: the unique index on order_id makes a replayed event a no-op,
# so at-least-once delivery still confirms exactly once.
class Order::Confirmation < ApplicationRecord
  belongs_to :order, touch: true

  # Recording the confirmation and sending the email happen as one unit: the
  # email only goes out on the first successful create, so a redelivery
  # (the relay re-sending the same event) never re-mails. The insert and the
  # send share a transaction, so if mail delivery fails transiently, the row
  # rolls back with it — the order isn't "confirmed" until the mail actually
  # went out, and the job's retry_on cleanly re-runs the whole thing.
  #
  # The tradeoff, stated plainly: the email is at-least-once, not exactly-once.
  # If deliver_now succeeds but the commit right after it fails, the retry
  # re-sends. And deliver_now is IO held open inside a DB transaction, so a slow
  # mail server holds the row's write locks; acceptable at this domain's scale,
  # and the honest boundary where a real system would move the send behind its
  # own outbox.
  #
  # requires_new: the savepoint that keeps the RecordNotUnique rescue survivable
  # on PostgreSQL (chapter 9).
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
