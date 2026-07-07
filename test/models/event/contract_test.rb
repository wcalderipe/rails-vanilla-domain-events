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

  test "a missing required key fails the delivery on the first execution" do
    event = @order.publish_event("order.paid", item: @order.item) # missing quantity
    delivery = Event::Delivery.create!(event:, subscriber: "Inventory::AdjustmentJob")

    delivery.fulfill { |e| Inventory::Adjustment.apply(e) }

    assert delivery.reload.failed?
    assert_equal "order.paid payload is missing quantity", delivery.error
    assert_equal 1, delivery.attempts # one execution happened; it failed terminally (N2)
  end

  test "a non-integer quantity fails the delivery on the first execution" do
    event = @order.publish_event("order.paid", item: @order.item, quantity: "a dozen")
    delivery = Event::Delivery.create!(event:, subscriber: "Inventory::AdjustmentJob")

    delivery.fulfill { |e| Inventory::Adjustment.apply(e) }

    assert delivery.reload.failed?
    assert_equal %(order.paid quantity is not an integer, got "a dozen"), delivery.error
  end

  test "a non-positive quantity fails the delivery on the first execution" do
    event = @order.publish_event("order.paid", item: @order.item, quantity: 0)
    delivery = Event::Delivery.create!(event:, subscriber: "Inventory::AdjustmentJob")

    delivery.fulfill { |e| Inventory::Adjustment.apply(e) }

    assert delivery.reload.failed?
    assert_equal "order.paid quantity must be positive, got 0", delivery.error
  end

  test "a violation never reaches the redelivery budget" do
    event = @order.publish_event("order.paid", item: @order.item)
    delivery = Event::Delivery.create!(event:, subscriber: "Inventory::AdjustmentJob")
    delivery.fulfill { |e| Inventory::Adjustment.apply(e) }

    travel Event::Delivery::REDELIVER_AFTER + 1.minute

    assert_no_enqueued_jobs do
      Event::Delivery.redeliver_stale
    end
    # Terminal after one execution: redelivery never touches it, and it never
    # climbs toward MAX_ATTEMPTS the way a transient failure would.
    assert delivery.reload.failed?
    assert_equal 1, delivery.attempts
  end

  test "a violation in one subscriber does not touch the healthy sibling" do
    event = @order.publish_event("order.paid", item: @order.item) # missing quantity
    broken = Event::Delivery.create!(event:, subscriber: "Inventory::AdjustmentJob")
    healthy = Event::Delivery.create!(event:, subscriber: "Order::ConfirmationJob")

    broken.fulfill { |e| Inventory::Adjustment.apply(e) }
    healthy.fulfill { |e| Order::Confirmation.record(e) }

    assert broken.reload.failed?
    assert healthy.reload.delivered?
    assert @order.reload.confirmed?
  end

  test "a violation mid-effect rolls the effect back but stamps the failure" do
    event = @order.publish_event("order.paid", item: @order.item, quantity: @order.quantity)
    delivery = Event::Delivery.create!(event:, subscriber: "Inventory::AdjustmentJob")

    delivery.fulfill do |e|
      Inventory::Adjustment.apply(e)
      raise Event::ContractViolation, "declared after a partial write"
    end

    assert delivery.reload.failed?
    assert_equal "declared after a partial write", delivery.error
    assert_equal 0, Inventory::Adjustment.where(event: event).count
  end

  test "an unexpected error still propagates and stays pending for tier 2" do
    event = @order.publish_event("order.paid", item: @order.item, quantity: @order.quantity)
    delivery = Event::Delivery.create!(event:, subscriber: "Inventory::AdjustmentJob")

    assert_raises RuntimeError do
      delivery.fulfill { raise "downstream blew up" }
    end

    assert_not delivery.reload.terminal?
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
