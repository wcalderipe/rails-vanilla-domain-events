require "test_helper"

class EventRelayGuardTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @order = orders(:keyboard)
    Event.dispatch_after_create = false
  end

  teardown do
    Event.dispatch_after_create = true
    Event.subscriptions.delete("order.poisoned")
  end

  test "one tick end to end: recovers the crash gap, sweeps stale deliveries, reports counts" do
    gapped = nil
    travel_to (Event::RELAY_AFTER + 1.minute).ago do
      gapped = @order.publish_event("order.paid", item: @order.item, quantity: @order.quantity)
    end
    dispatched = orders(:mouse).publish_event("order.shipped", item: "mouse", quantity: 1)
    dispatched.dispatch
    stale = Event::Delivery.create!(event: dispatched, subscriber: "Order::ConfirmationJob")
    stale.update!(updated_at: (Event::Delivery::REDELIVER_AFTER + 1.minute).ago)

    assert_in_delta Event::RELAY_AFTER + 1.minute, Event.oldest_stranded_age, 5.seconds

    signals = capture_relay_signal { Event::RelayJob.perform_now }

    assert gapped.reload.dispatched?
    assert_equal 2, gapped.deliveries.count
    assert_equal 0, stale.reload.attempts # redelivery enqueues; attempts counts executions
    assert_equal [ [ "event_relay.swept", { stranded: 1, redelivered: 1, failed: 0 } ] ], signals
    assert_nil Event.oldest_stranded_age
  end

  test "one tick end to end: poison in both tiers, healthy work still done, poison reported not lost" do
    with_doomed_subscriber do
      poison_event = healthy_event = nil
      travel_to (Event::RELAY_AFTER + 1.minute).ago do
        poison_event = @order.publish_event("order.poisoned", item: @order.item)
        healthy_event = @order.publish_event("order.paid", item: @order.item, quantity: 1)
      end
      dispatched = orders(:mouse).publish_event("order.shipped", item: "mouse", quantity: 1)
      dispatched.dispatch
      poison_delivery = Event::Delivery.create!(event: dispatched, subscriber: "GhostJob")
      healthy_delivery = Event::Delivery.create!(event: dispatched, subscriber: "Order::ConfirmationJob")
      Event::Delivery.update_all(updated_at: (Event::Delivery::REDELIVER_AFTER + 1.minute).ago)

      signals = capture_relay_signal { Event::RelayJob.perform_now }

      assert healthy_event.reload.dispatched?
      assert_equal 0, healthy_delivery.reload.attempts # redelivery enqueues; attempts counts executions
      assert_not poison_event.reload.dispatched?
      assert_not poison_delivery.reload.terminal?
      assert_equal [ [ "event_relay.swept", { stranded: 1, redelivered: 1, failed: 0 } ] ], signals
      assert_in_delta Event::RELAY_AFTER + 1.minute, Event.oldest_stranded_age, 5.seconds
    end
  end

  test "a poison event does not block the events behind it" do
    with_doomed_subscriber do
      poison = healthy = nil
      travel_to (Event::RELAY_AFTER + 1.minute).ago do
        poison = @order.publish_event("order.poisoned", item: @order.item)
        healthy = @order.publish_event("order.paid", item: @order.item, quantity: 1)
      end

      swept = Event.relay_stranded

      assert_not poison.reload.dispatched?
      assert healthy.reload.dispatched?
      assert_equal 1, swept
    end
  end

  test "a poison delivery does not block the deliveries behind it" do
    event = @order.publish_event("order.paid", item: @order.item, quantity: 1)
    poison = Event::Delivery.create!(event:, subscriber: "GhostJob")
    healthy = Event::Delivery.create!(event:, subscriber: "Order::ConfirmationJob")
    Event::Delivery.update_all(updated_at: (Event::Delivery::REDELIVER_AFTER + 1.minute).ago)

    redelivered, failed = Event::Delivery.redeliver_stale

    assert_equal 1, redelivered
    assert_equal 0, failed
    assert_equal 0, healthy.reload.attempts # redelivery enqueues; attempts counts executions
    assert_not poison.reload.terminal?
    assert_enqueued_with job: Order::ConfirmationJob, args: [ healthy ]
  end

  test "oldest_pending_age reads the deliveries' backlog" do
    assert_nil Event::Delivery.oldest_pending_age

    event = @order.publish_event("order.paid", item: @order.item, quantity: 1)
    delivery = Event::Delivery.create!(event:, subscriber: "Order::ConfirmationJob")
    delivery.update!(updated_at: 10.minutes.ago)

    assert_in_delta 10.minutes, Event::Delivery.oldest_pending_age, 5.seconds
  end

  private
    # A subscriber that exists at registration (subscribe eager-constantizes)
    # but is gone by dispatch time: the honest poison, no stubs.
    def with_doomed_subscriber
      Object.const_set(:DoomedJob, Class.new(ApplicationJob))
      Event.subscribe("order.poisoned", "DoomedJob")
      Object.send(:remove_const, :DoomedJob)
      yield
    end

    # Captures through the event reporter's own subscriber API, so the test
    # exercises the same path a production log subscriber would.
    class SignalCapture
      attr_reader :signals

      def initialize = @signals = []
      def emit(event) = @signals << [ event[:name], event[:payload] ]
    end

    def capture_relay_signal
      capture = SignalCapture.new
      Rails.event.subscribe(capture)
      yield
      capture.signals.select { |name, _| name == "event_relay.swept" }
    ensure
      Rails.event.unsubscribe(capture)
    end
end
