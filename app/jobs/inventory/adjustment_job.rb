class Inventory::AdjustmentJob < ApplicationJob
  queue_as :default

  def perform(delivery)
    delivery.fulfill { |event| Inventory::Adjustment.apply(event) }
  end
end
