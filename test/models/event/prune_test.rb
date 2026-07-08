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

  test "an old event with every delivery terminal is pruned, deliveries included" do
    event = aged_event
    event.deliveries.create!(subscriber: "Order::ConfirmationJob", delivered_at: Time.current)
    event.deliveries.create!(subscriber: "Inventory::AdjustmentJob", failed_at: Time.current, error: "boom")

    assert_equal 1, Event.prune

    assert_not Event.exists?(event.id)
    assert_equal 0, Event::Delivery.count
  end

  test "an old event with one pending delivery is kept, whatever its age" do
    event = aged_event
    event.deliveries.create!(subscriber: "Order::ConfirmationJob", delivered_at: Time.current)
    event.deliveries.create!(subscriber: "Inventory::AdjustmentJob")

    assert_equal 0, Event.prune
    assert Event.exists?(event.id)
  end

  test "a young event is kept even with every delivery terminal" do
    event = @order.publish_event("order.paid", item: @order.item, quantity: 1)
    event.update!(dispatched_at: Time.current)
    event.deliveries.create!(subscriber: "Order::ConfirmationJob", delivered_at: Time.current)

    assert_equal 0, Event.prune
    assert Event.exists?(event.id)
  end

  test "an old dispatched event with no subscribers is pruned by age alone" do
    event = aged_event

    assert_equal 1, Event.prune
    assert_not Event.exists?(event.id)
  end

  test "an old stranded event is never pruned: its fanout is still owed" do
    event = travel_to (Event::RETENTION + 1.day).ago do
      @order.publish_event("order.shipped", item: @order.item, quantity: 1)
    end

    assert_equal 0, Event.prune
    assert Event.exists?(event.id)
  end

  test "the prune job reports the swept count as a liveness signal" do
    aged_event
    aged_event(order: orders(:mouse))

    signals = capture_prune_signal { Event::PruneJob.perform_now }

    assert_equal [ [ "event_prune.swept", { pruned: 2 } ] ], signals
    assert_equal 0, Event.count
  end

  private
    def aged_event(order: @order)
      travel_to (Event::RETENTION + 1.day).ago do
        event = order.publish_event("order.paid", item: order.item, quantity: 1)
        event.update!(dispatched_at: Time.current)
        event
      end
    end

    class SignalCapture
      attr_reader :signals

      def initialize = @signals = []
      def emit(event) = @signals << [ event[:name], event[:payload] ]
    end

    def capture_prune_signal
      capture = SignalCapture.new
      Rails.event.subscribe(capture)
      yield
      capture.signals.select { |name, _| name == "event_prune.swept" }
    ensure
      Rails.event.unsubscribe(capture)
    end
end
