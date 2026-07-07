require "test_helper"

class Order::ConfirmationTest < ActiveSupport::TestCase
  setup do
    Event.dispatch_after_create = false
    @order = orders(:keyboard)
    @event = @order.publish_event("order.paid", item: @order.item, quantity: @order.quantity)
  end

  teardown do
    Event.dispatch_after_create = true
  end

  test "record confirms the order once no matter how many deliveries" do
    assert_difference -> { Order::Confirmation.count }, 1 do
      Order::Confirmation.record(@event)
      Order::Confirmation.record(@event)
    end
    assert @order.reload.confirmed?
  end
end
