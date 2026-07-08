require "test_helper"

# Chapter 5's problem, proven defense by defense: every layer built so far is
# doing its job correctly, and none of them owns publication identity. Each
# test below exercises one existing defense against the same scenario (the
# same fact published twice) and shows where it stops.
class EventPublicationTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @order = orders(:keyboard)
  end

  test "event-id dedup catches duplicate deliveries, not duplicate publications" do
    # Inventory::Adjustment is unique on event_id: replays of ONE row apply
    # once. Two publications are two rows with two ids, so it applies both.
    perform_enqueued_jobs do
      2.times { publish_paid_fact }
    end

    assert_equal Inventory::STARTING_STOCK - (@order.quantity * 2), Inventory.on_hand(@order.item)
  end

  test "natural-key dedup absorbs the duplicate only because its key is domain-scoped" do
    # Order::Confirmation is unique on order_id, so it happens to collapse the
    # two publications. That is luck of the key choice, not a property of the
    # mechanism: the previous test shows the same mechanism failing.
    perform_enqueued_jobs do
      2.times { publish_paid_fact }
    end

    assert_equal 1, Order::Confirmation.where(order: @order).count
  end

  test "delivery records treat two publications as two legitimate fanouts" do
    # Chapter 3 dedupes per (event, subscriber). Two events mean two
    # deliveries per subscriber, both correct from its point of view.
    events = perform_enqueued_jobs do
      2.times.map { publish_paid_fact }
    end

    deliveries = Event::Delivery.where(event: events, subscriber: "Inventory::AdjustmentJob")
    assert_equal 2, deliveries.count
    assert deliveries.all?(&:delivered?)
  end

  test "the relay re-announces an existing row and never mints a second" do
    Event.dispatch_after_create = false
    event = travel_to (Event::RELAY_AFTER + 1.minute).ago do
      publish_paid_fact
    end

    assert_no_difference -> { Event.count } do
      Event.relay_stranded
    end
    assert event.reload.dispatched?
  ensure
    Event.dispatch_after_create = true
  end

  test "a fact anchored in a unique state record cannot publish twice" do
    # Order#pay creates the payment and the event in one transaction. The
    # unique index on order_payments aborts the second pay before its event
    # row exists, so the duplicate fact dies with the losing transaction.
    @order.pay

    assert_no_difference -> { Event.count } do
      assert_raises ActiveRecord::RecordInvalid do
        @order.reload.pay
      end
    end
  end

  test "republishing with the same idempotence key applies effects exactly once" do
    first = second = nil

    perform_enqueued_jobs do
      first = publish_paid_fact(idempotence_key: "order.paid/#{@order.id}")
      second = publish_paid_fact(idempotence_key: "order.paid/#{@order.id}")
    end

    assert_equal first.id, second.id
    assert_equal 1, @order.events.where(action: "order.paid").count
    assert_equal Inventory::STARTING_STOCK - @order.quantity, Inventory.on_hand(@order.item)
    assert_equal 1, Order::Confirmation.where(order: @order).count
  end

  test "different keys record different facts" do
    publish_paid_fact(idempotence_key: "order.paid/#{@order.id}/1")
    publish_paid_fact(idempotence_key: "order.paid/#{@order.id}/2")

    assert_equal 2, @order.events.where(action: "order.paid").count
  end

  test "a nil key opts out of publication dedup" do
    2.times { publish_paid_fact }

    assert_equal 2, @order.events.where(action: "order.paid").count
  end

  test "the idempotence key is a global identity: reused across eventables, recovery returns the first fact" do
    other = orders(:mouse)
    first = publish_paid_fact(idempotence_key: "shared/key")

    # A different eventable reuses the same key. The unique index is global
    # (idempotence IS NOT NULL), so the second insert is rejected — and recovery
    # must hand back the already-recorded fact, not look only inside this
    # eventable's association (where it does not exist) and raise RecordNotFound.
    second = other.publish_event("order.paid", item: other.item, quantity: other.quantity,
                                 idempotence_key: "shared/key")

    assert_equal first, second
    assert_equal 1, Event.where(idempotence_key: "shared/key").count
  end

  test "the idempotence key is immutable once persisted" do
    event = publish_paid_fact(idempotence_key: "order.paid/#{@order.id}")

    assert_raises ActiveRecord::ReadonlyAttributeError do
      event.idempotence_key = "another"
    end
  end

  private
    def publish_paid_fact(**options)
      @order.publish_event("order.paid", item: @order.item, quantity: @order.quantity, **options)
    end
end
