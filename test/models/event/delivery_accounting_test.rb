require "test_helper"

# N2: `attempts` is the delivery's retry budget, and MAX_ATTEMPTS turns it into
# a terminal failure. It must therefore count real EXECUTIONS, not enqueues —
# otherwise a queue outage or an overlapping relay spends the budget against a
# delivery that never ran, and a live effect is marked permanently failed.
class Event::DeliveryAccountingTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    Event.dispatch_after_create = false
    @order = orders(:keyboard)
    @event = @order.publish_event("order.paid", item: @order.item, quantity: 1)
    @delivery = Event::Delivery.create!(event: @event, subscriber: "Inventory::AdjustmentJob")
  end

  teardown { Event.dispatch_after_create = true }

  test "enqueuing does not spend an attempt" do
    assert_no_difference -> { @delivery.reload.attempts } do
      @delivery.deliver_later
    end
  end

  test "executing spends exactly one attempt, even when the effect fails and rolls back" do
    assert_difference -> { @delivery.reload.attempts }, 1 do
      assert_raises(RuntimeError) { @delivery.fulfill { raise "downstream blew up" } }
    end
  end

  test "sweeps that only enqueue never exhaust the budget, so a never-executed delivery is never failed" do
    # The worker is down: every sweep re-enqueues, no job ever runs. Far more
    # sweeps than MAX_ATTEMPTS, yet the budget is untouched and the delivery
    # stays pending — the loss the old enqueue-counting accounting produced.
    (Event::Delivery::MAX_ATTEMPTS * 3).times do
      @delivery.update_columns(updated_at: (Event::Delivery::REDELIVER_AFTER + 1.minute).ago)
      Event::Delivery.redeliver_stale
    end

    @delivery.reload
    assert_equal 0, @delivery.attempts
    assert_not @delivery.failed?, "a delivery that never executed must not be marked failed"
  end

  test "mark_failed does not overwrite an already-delivered effect" do
    @delivery.fulfill { |event| Inventory::Adjustment.apply(event) }
    assert @delivery.delivered?

    # A tier-2 exhaustion racing the just-committed effect must not flip it:
    @delivery.mark_failed(error: "late exhaustion")

    @delivery.reload
    assert @delivery.delivered?
    assert_not @delivery.failed?, "a delivered effect must never carry failed_at too"
  end
end
