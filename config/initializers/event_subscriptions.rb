Rails.application.config.to_prepare do
  # Downstream side effects subscribe to domain events here. Events with
  # no subscribers (order.placed, order.shipped) are still recorded — the
  # log is history regardless of who's listening.
  Event.subscribe("order.paid", "Order::ConfirmationJob")
  Event.subscribe("order.paid", "Inventory::AdjustmentJob")
end
