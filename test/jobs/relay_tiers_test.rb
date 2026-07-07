require "test_helper"

# N4: the relay runs tier 1 (re-dispatch stranded events) then tier 2
# (redeliver stale deliveries) in one tick. A crash mid-fanout leaves an event
# stranded WITH a pending delivery, so both tiers can see the same delivery.
# It must be re-driven once per tick, not twice.
class RelayTiersTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    Event.dispatch_after_create = false
    @order = orders(:keyboard)
  end

  teardown { Event.dispatch_after_create = true }

  test "a stranded event with a stale delivery is re-driven once, not by both tiers" do
    event = @order.publish_event("order.paid", item: @order.item, quantity: 1)
    # Crash mid-fanout: the confirmation delivery row exists and was enqueued,
    # but dispatched_at was never stamped and the job never ran.
    delivery = Event::Delivery.create!(event:, subscriber: "Order::ConfirmationJob")
    event.update_columns(dispatched_at: nil, created_at: (Event::RELAY_AFTER + 1.minute).ago)
    delivery.update_columns(updated_at: (Event::Delivery::REDELIVER_AFTER + 1.minute).ago)

    # Tier 1 re-dispatches the event (re-enqueuing this delivery); tier 2 must
    # then leave it alone, because tier 1 already owns it this tick.
    assert_enqueued_jobs 1, only: Order::ConfirmationJob do
      Event::RelayJob.perform_now
    end
  end
end
