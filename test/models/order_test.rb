require "test_helper"

class OrderTest < ActiveSupport::TestCase
  setup do
    @order = orders(:keyboard)
  end

  test "place creates the order" do
    order = Order.place(customer_email: "dave@example.com", item: "monitor", quantity: 3)

    assert order.persisted?
    assert_equal "monitor", order.item
  end

  test "pay creates the payment" do
    @order.pay
    assert @order.paid?
  end

  test "paying twice raises" do
    @order.pay

    assert_raises ActiveRecord::RecordInvalid do
      @order.reload.pay
    end
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
