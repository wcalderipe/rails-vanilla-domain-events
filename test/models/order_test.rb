require "test_helper"

class OrderTest < ActiveSupport::TestCase
  setup do
    @order = orders(:keyboard)
  end

  test "place creates the order and records order.placed atomically" do
    order = nil
    assert_difference -> { Event.count }, 1 do
      order = Order.place(customer_email: "dave@example.com", item: "monitor", quantity: 3)
    end

    event = order.events.chronologically.last
    assert_equal "order.placed", event.action
    assert_equal({ "item" => "monitor", "quantity" => 3 }, event.payload)
  end

  test "pay creates the payment and records order.paid" do
    assert_difference -> { Event.count }, 1 do
      @order.pay
    end
    assert @order.paid?
    assert_equal "order.paid", @order.events.chronologically.last.action
  end

  test "paying twice raises" do
    @order.pay

    assert_raises ActiveRecord::RecordInvalid do
      @order.reload.pay
    end
  end

  test "paying an order confirms it and adjusts inventory" do
    perform_enqueued_jobs do
      @order.pay
    end

    assert @order.reload.confirmed?
    assert_equal Inventory::STARTING_STOCK - @order.quantity, Inventory.on_hand(@order.item)
  end

  test "ship requires payment" do
    assert_raises Order::UnpaidOrder do
      @order.ship
    end

    @order.pay
    @order.ship
    assert @order.shipped?
  end

  test "paid scope reflects the payment record" do
    @order.pay
    assert_includes Order.paid, @order
    assert_not_includes Order.unpaid, @order
  end
end
