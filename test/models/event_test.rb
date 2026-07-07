require "test_helper"

class EventTest < ActiveSupport::TestCase
  setup do
    @order = orders(:keyboard)
    Event.dispatch_after_create = false
  end

  teardown do
    Event.dispatch_after_create = true
  end

  test "subscribing an unknown class explodes at registration" do
    assert_raises NameError do
      Event.subscribe("order.paid", "Order::TypoJob")
    end
    assert_not_includes Event.subscribers_for("order.paid"), "Order::TypoJob"
  end

  test "publish_event records the fact in the caller's transaction" do
    assert_no_difference -> { Event.count } do
      Order.transaction do
        @order.publish_event("order.paid", item: @order.item)
        raise ActiveRecord::Rollback
      end
    end
  end

  test "the fact is immutable once persisted" do
    event = @order.publish_event("order.paid", item: @order.item)

    assert_raises ActiveRecord::ReadonlyAttributeError do
      event.action = "order.refunded"
    end
  end

  test "dispatch creates one delivery per subscriber, enqueues each, and marks the fanout done" do
    event = @order.publish_event("order.paid", item: @order.item, quantity: 1)

    assert_enqueued_jobs 2 do
      event.dispatch
    end
    assert event.dispatched?
    assert_equal %w[Inventory::AdjustmentJob Order::ConfirmationJob], event.deliveries.pluck(:subscriber).sort
    event.deliveries.each do |delivery|
      assert_enqueued_with job: delivery.subscriber.constantize, args: [ delivery ]
      assert_equal 1, delivery.attempts
    end
  end

  test "re-running dispatch after a mid-fanout crash does not duplicate deliveries" do
    event = @order.publish_event("order.paid", item: @order.item, quantity: 1)
    Event::Delivery.create!(event:, subscriber: "Order::ConfirmationJob")

    event.dispatch

    assert_equal 2, event.deliveries.count
    assert_equal 1, event.deliveries.where(subscriber: "Order::ConfirmationJob").count
  end

  test "dispatch is a no-op when the fanout already completed" do
    event = @order.publish_event("order.paid", item: @order.item, quantity: 1)
    event.dispatch

    assert_no_enqueued_jobs do
      event.dispatch
    end
  end

  test "an action without subscribers still marks the fanout done" do
    event = @order.publish_event("order.shipped", item: @order.item)

    assert_no_enqueued_jobs { event.dispatch }
    assert event.dispatched?
  end

  test "stranded finds old undispatched events only" do
    stranded = fresh = dispatched = nil

    travel_to (Event::RELAY_AFTER + 1.minute).ago do
      stranded = @order.publish_event("order.paid", item: @order.item)
      dispatched = @order.publish_event("order.shipped", item: @order.item)
      dispatched.dispatch
    end
    fresh = @order.publish_event("order.placed", item: @order.item)

    assert_includes Event.stranded, stranded
    assert_not_includes Event.stranded, fresh
    assert_not_includes Event.stranded, dispatched
  end

  test "relay_stranded re-dispatches every stranded event" do
    event = travel_to (Event::RELAY_AFTER + 1.minute).ago do
      @order.publish_event("order.paid", item: @order.item, quantity: 1)
    end

    assert_enqueued_jobs 2 do
      Event.relay_stranded
    end
    assert event.reload.dispatched?
  end
end
