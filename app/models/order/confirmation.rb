# The customer-notification effect of order.paid. Idempotent by natural
# key: the unique index on order_id makes a replayed event a no-op, so
# at-least-once delivery confirms exactly once.
class Order::Confirmation < ApplicationRecord
  belongs_to :order, touch: true

  def self.record(event)
    create!(order: event.eventable)
  rescue ActiveRecord::RecordNotUnique
    find_by(order_id: event.eventable_id)
  end
end
