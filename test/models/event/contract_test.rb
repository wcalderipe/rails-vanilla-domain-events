require "test_helper"

class Event::ContractTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @order = orders(:keyboard)
    Event.dispatch_after_create = false
  end

  teardown do
    Event.dispatch_after_create = true
  end

  test "a malformed payload burns the whole redelivery budget before anyone is paged" do
    event = @order.publish_event("order.paid", item: @order.item) # missing quantity
    delivery = Event::Delivery.create!(event:, subscriber: "Inventory::AdjustmentJob")

    Event::Delivery::MAX_ATTEMPTS.times do
      assert_raises KeyError do
        delivery.fulfill { |e| Inventory::Adjustment.apply(e) }
      end
      assert_not delivery.reload.terminal?

      travel Event::Delivery::REDELIVER_AFTER + 1.minute
      Event::Delivery.redeliver_stale
    end

    assert_equal Event::Delivery::MAX_ATTEMPTS, delivery.reload.attempts

    travel Event::Delivery::REDELIVER_AFTER + 1.minute
    Event::Delivery.redeliver_stale

    assert delivery.reload.failed?
    assert_equal "redelivery attempts exhausted", delivery.error
  end

  test "extra unknown payload keys never break a consumer" do
    event = @order.publish_event(
      "order.paid",
      item: @order.item, quantity: @order.quantity, customer_email: @order.customer_email,
      coupon: "SUMMER10", channel: "web"
    )

    assert_difference -> { Inventory::Adjustment.count }, 1 do
      Inventory::Adjustment.apply(event)
    end
    assert_difference -> { Order::Confirmation.count }, 1 do
      Order::Confirmation.record(event)
    end
  end
end
