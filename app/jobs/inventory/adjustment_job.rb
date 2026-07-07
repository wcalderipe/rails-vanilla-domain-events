class Inventory::AdjustmentJob < ApplicationJob
  queue_as :default

  def perform(event) = Inventory::Adjustment.apply(event)
end
