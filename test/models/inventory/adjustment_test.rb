require "test_helper"

class Inventory::AdjustmentTest < ActiveSupport::TestCase
  setup do
    Event.dispatch_after_create = false
    @order = orders(:keyboard)
    @event = @order.track_event("order.paid", item: @order.item, quantity: @order.quantity)
  end

  teardown do
    Event.dispatch_after_create = true
  end

  test "apply adjusts stock by the event's quantity" do
    Inventory::Adjustment.apply(@event)

    assert_equal Inventory::STARTING_STOCK - @order.quantity, Inventory.on_hand(@order.item)
  end

  test "the same event applies at most one adjustment" do
    assert_difference -> { Inventory::Adjustment.count }, 1 do
      Inventory::Adjustment.apply(@event)
      Inventory::Adjustment.apply(@event)
    end
  end
end
