require "test_helper"

# Question 6: processing order is not guaranteed (parallel workers, retry
# backoff, tier-2 redelivery), so these tests apply effects in an order that
# contradicts emission order and document how each consumer posture reacts.
class EventOrderingTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  class MissingPrecondition < StandardError; end

  # Test-only, deliberately order-sensitive: keeps whatever it processed
  # last, the shape a real projection has when it trusts arrival order.
  class LastWriteWinsStatus
    cattr_accessor :status, default: {}

    def self.apply(event)
      status[event.eventable_id] = event.action
    end
  end

  # The third posture: an effect that requires an earlier fact's effect
  # raises until that effect lands, riding chapter 2's retry_on as the
  # reordering mechanism. wait: 0 so the test flushes retries without clocks.
  class ShipmentNoticeJob < ApplicationJob
    cattr_accessor :notified, default: []
    cattr_accessor :performed_attempts, default: []

    retry_on MissingPrecondition, wait: 0.seconds, attempts: 5

    def perform(event)
      self.class.performed_attempts << executions
      raise MissingPrecondition unless event.eventable.reload.confirmed?

      notified << event.eventable_id
    end
  end

  setup do
    @order = orders(:keyboard)
    Event.dispatch_after_create = false
    LastWriteWinsStatus.status = {}
    ShipmentNoticeJob.notified = []
    ShipmentNoticeJob.performed_attempts = []
  end

  teardown do
    Event.dispatch_after_create = true
  end

  test "one-shot and derived consumers converge under reversed processing" do
    first = orders(:keyboard).publish_event("order.paid", item: "keyboard", quantity: 2)
    second = orders(:mouse).publish_event("order.paid", item: "keyboard", quantity: 3)

    # Effects land in the opposite of emission order.
    [ second, first ].each do |event|
      Order::Confirmation.record(event)
      Inventory::Adjustment.apply(event)
    end

    assert_equal Inventory::STARTING_STOCK - 5, Inventory.on_hand("keyboard")
    assert orders(:keyboard).reload.confirmed?
    assert orders(:mouse).reload.confirmed?
  end

  test "the log records emission order even when processing scrambles it" do
    paid = @order.publish_event("order.paid", item: @order.item, quantity: 1)
    shipped = @order.publish_event("order.shipped", item: @order.item, quantity: 1)

    LastWriteWinsStatus.apply(shipped)
    LastWriteWinsStatus.apply(paid)

    assert_equal [ paid, shipped ], @order.events.chronologically.to_a
  end

  test "a last-write-wins projection ends wrong under reversed processing" do
    paid = @order.publish_event("order.paid", item: @order.item, quantity: 1)
    shipped = @order.publish_event("order.shipped", item: @order.item, quantity: 1)

    LastWriteWinsStatus.apply(shipped)
    LastWriteWinsStatus.apply(paid)

    # Wrong on purpose: the order shipped, but the projection trusted arrival
    # order. This documents the hazard; protection is consumer posture, not
    # the mechanism.
    assert_equal "order.paid", LastWriteWinsStatus.status[@order.id]
  end

  test "a precondition-gated consumer converges via retry when effects arrive reversed" do
    paid = @order.publish_event("order.paid", item: @order.item, quantity: @order.quantity)
    shipped = @order.publish_event("order.shipped", item: @order.item, quantity: @order.quantity)

    # The shipped effect is attempted before the paid effect has landed.
    ShipmentNoticeJob.perform_later(shipped)
    confirmation = Event::Delivery.create!(event: paid, subscriber: "Order::ConfirmationJob")
    Order::ConfirmationJob.perform_later(confirmation)

    # Each flush drains the current queue; the failed notice re-enqueues
    # behind the confirmation, which is the reordering.
    3.times { perform_enqueued_jobs }

    assert_equal [ @order.id ], ShipmentNoticeJob.notified
    assert_operator ShipmentNoticeJob.performed_attempts.size, :>, 1
    assert @order.reload.confirmed?
  end
end
