# The inventory effect of order.paid. Idempotent by event id: the unique
# index on event_id means one event applies at most one adjustment, no
# matter how many times it's redelivered.
#
# This consumer's required keys are declared here, at the fetch site: the
# emitter owns the payload schema, the consumer owns what it requires from it.
class Inventory::Adjustment < ApplicationRecord
  self.table_name = "inventory_adjustments"

  belongs_to :event

  validates :item, presence: true
  validates :delta, numericality: { other_than: 0 }

  # requires_new: the savepoint that keeps the rescue safe on PostgreSQL
  # (chapter 9).
  def self.apply(event)
    transaction(requires_new: true) do
      create!(
        event:,
        item: required(event, "item"),
        delta: -required_quantity(event)
      )
    end
  rescue ActiveRecord::RecordNotUnique
    find_by(event_id: event.id)
  end

  def self.required(event, key)
    event.payload.fetch(key) do
      raise Event::ContractViolation, "#{event.action} payload is missing #{key}"
    end
  end

  def self.required_quantity(event)
    value = required(event, "quantity")
    quantity = Integer(value)

    if quantity.positive?
      quantity
    else
      raise Event::ContractViolation, "#{event.action} quantity must be positive, got #{value.inspect}"
    end
  rescue TypeError, ArgumentError
    raise Event::ContractViolation, "#{event.action} quantity is not an integer, got #{value.inspect}"
  end
end
