require "test_helper"

# Chapter 4's concurrency semaphore is a fixed-TTL lease, not a lock held
# for the job's lifetime. A relay tick that runs longer than the lease
# (default 3 min) has the lease reaped WHILE IT IS STILL RUNNING, and the next
# scheduled tick runs concurrently — reintroducing the double-dispatch the
# semaphore was meant to prevent. The defense is to keep a tick short by
# bounding each sweep, so a backlog drains over several short ticks instead of
# one unbounded one. These tests pin the bound (the semaphore itself is inert
# under the :test adapter, so it cannot be asserted directly).
class RelayBatchTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    Event.dispatch_after_create = false
    @order = orders(:keyboard)
  end

  teardown { Event.dispatch_after_create = true }

  test "tier 1 dispatches at most RELAY_BATCH events, leaving the rest for the next tick" do
    with_relay_batch(2) do
      3.times { create_stranded_event }
      assert_equal 3, Event.stranded.count

      swept = Event.relay_stranded

      assert_equal 2, swept
      assert_equal 1, Event.stranded.count, "the overflow event waits for the next tick"
    end
  end

  test "tier 2 redelivery is bounded per tick the same way" do
    with_relay_batch(2) do
      3.times { create_stale_delivery }

      assert_enqueued_jobs 2 do
        Event::Delivery.redeliver_stale
      end
    end
  end

  private
    def create_stranded_event
      event = @order.publish_event("order.paid", item: @order.item, quantity: 1)
      event.update_columns(dispatched_at: nil, created_at: (Event::RELAY_AFTER + 1.minute).ago)
      event
    end

    def create_stale_delivery
      event = @order.publish_event("order.paid", item: @order.item, quantity: 1)
      event.update_columns(dispatched_at: Time.current)
      delivery = Event::Delivery.create!(event:, subscriber: "Inventory::AdjustmentJob")
      delivery.update_columns(updated_at: (Event::Delivery::REDELIVER_AFTER + 1.minute).ago)
      delivery
    end

    def with_relay_batch(size)
      original = Event::RELAY_BATCH
      silence_warnings { Event.const_set(:RELAY_BATCH, size) }
      yield
    ensure
      silence_warnings { Event.const_set(:RELAY_BATCH, original) }
    end
end
