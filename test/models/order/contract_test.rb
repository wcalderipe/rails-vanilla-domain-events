require "test_helper"

# The emitter owns the payload schema, and these tests are that schema's
# source of truth: renaming or removing a key breaks the build here, on the
# emitter's side, instead of in production on a consumer's side.
class Order::ContractTest < ActiveSupport::TestCase
  setup do
    @order = orders(:keyboard)
    Event.dispatch_after_create = false
  end

  teardown do
    Event.dispatch_after_create = true
  end

  test "order.placed publishes item and quantity" do
    order = Order.place(customer_email: "dave@example.com", item: "monitor", quantity: 3)
    event = order.events.chronologically.last

    assert_equal({ "item" => "monitor", "quantity" => 3 }, event.payload)
  end

  test "order.paid publishes item, quantity, and customer_email" do
    @order.pay
    event = @order.events.chronologically.last

    assert_equal %w[customer_email item quantity], event.payload.keys.sort
    assert_equal @order.quantity, event.payload["quantity"]
  end

  test "order.shipped publishes item and quantity" do
    @order.pay
    @order.ship
    event = @order.events.chronologically.last

    assert_equal %w[item quantity], event.payload.keys.sort
  end
end
