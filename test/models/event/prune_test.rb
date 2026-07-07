require "test_helper"

class Event::PruneTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @order = orders(:keyboard)
    Event.dispatch_after_create = false
  end

  teardown do
    Event.dispatch_after_create = true
  end

  # Permanent documentation of why the prune guard exists. Deleting an event
  # whose job has not run yet takes the delivery with it; the enqueued job
  # deserializes nothing, chapter 2's discard_on swallows the error, and the
  # effect is dropped with no trace: no confirmation, no failed delivery,
  # nothing terminal for a human to find. Retention must never touch work
  # that is still owed.
  test "deleting an event with an enqueued job silently drops the effect" do
    event = @order.publish_event("order.paid", item: @order.item, quantity: @order.quantity)
    delivery = Event::Delivery.create!(event:, subscriber: "Order::ConfirmationJob")
    Order::ConfirmationJob.perform_later(delivery)
    event.destroy

    assert_nothing_raised do
      perform_enqueued_jobs
    end

    assert_not @order.reload.confirmed?
    assert_equal 0, Event::Delivery.count
  end
end
