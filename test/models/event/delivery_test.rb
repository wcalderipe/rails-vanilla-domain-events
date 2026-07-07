require "test_helper"

class Event::DeliveryTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @order = orders(:keyboard)
    Event.dispatch_after_create = false
    @event = @order.publish_event("order.paid", item: @order.item, quantity: @order.quantity)
    @delivery = Event::Delivery.create!(event: @event, subscriber: "Order::ConfirmationJob")
  end

  teardown do
    Event.dispatch_after_create = true
  end

  test "fulfill runs the effect and acknowledges atomically" do
    @delivery.fulfill { |event| Order::Confirmation.record(event) }

    assert @delivery.delivered?
    assert @order.reload.confirmed?
  end

  test "a failing effect leaves the delivery pending" do
    assert_raises RuntimeError do
      @delivery.fulfill { raise "downstream blew up" }
    end

    assert_not @delivery.reload.terminal?
  end

  test "fulfill is a no-op on a terminal delivery" do
    @delivery.fulfill { |event| Order::Confirmation.record(event) }

    ran = false
    @delivery.fulfill { ran = true }

    assert_not ran
  end

  test "a stale pending delivery is redelivered by tier 2" do
    @delivery.update!(updated_at: (Event::Delivery::REDELIVER_AFTER + 1.minute).ago)

    assert_enqueued_with job: Order::ConfirmationJob, args: [ @delivery ] do
      Event::Delivery.redeliver_stale
    end
    assert_equal 1, @delivery.reload.attempts
  end

  test "a fresh pending delivery is left alone" do
    assert_no_enqueued_jobs do
      Event::Delivery.redeliver_stale
    end
  end

  test "exhausted redeliveries land in the terminal failed state, not another loop" do
    @delivery.update!(attempts: Event::Delivery::MAX_ATTEMPTS,
                      updated_at: (Event::Delivery::REDELIVER_AFTER + 1.minute).ago)

    assert_no_enqueued_jobs do
      Event::Delivery.redeliver_stale
    end

    assert @delivery.reload.failed?
    assert_equal "redelivery attempts exhausted", @delivery.error
  end

  test "one subscriber failing does not hide that the other finished" do
    other = Event::Delivery.create!(event: @event, subscriber: "Inventory::AdjustmentJob")
    other.fulfill { |event| Inventory::Adjustment.apply(event) }
    @delivery.mark_failed(error: "boom")

    assert other.delivered?
    assert @delivery.failed?
  end
end
