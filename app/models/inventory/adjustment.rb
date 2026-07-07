# The inventory effect of order.paid. Idempotent by event id: the unique
# index on event_id means the same event applies at most one adjustment, no
# matter how many times the relay re-delivers it.
class Inventory::Adjustment < ApplicationRecord
  self.table_name = "inventory_adjustments"

  belongs_to :event

  validates :item, presence: true
  validates :delta, numericality: { other_than: 0 }

  def self.apply(event)
    create!(
      event:,
      item: event.payload.fetch("item"),
      delta: -event.payload.fetch("quantity").to_i
    )
  rescue ActiveRecord::RecordNotUnique
    find_by(event_id: event.id)
  end
end
