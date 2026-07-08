require "test_helper"

class SubscriberRetryTest < ActiveJob::TestCase
  class TransientError < StandardError; end
  class PermanentError < StandardError; end

  class FlakyJob < ApplicationJob
    cattr_accessor :performed_attempts, default: []
    cattr_accessor :exhausted, default: []

    retry_on TransientError, wait: 1.second, attempts: 3 do |_job, error|
      exhausted << error.class
    end

    def perform(fail_times:)
      self.class.performed_attempts << executions
      raise TransientError if executions <= fail_times
    end
  end

  class BrittleJob < ApplicationJob
    cattr_accessor :performed_attempts, default: []

    def perform
      self.class.performed_attempts << executions
      raise PermanentError
    end
  end

  setup do
    FlakyJob.performed_attempts = []
    FlakyJob.exhausted = []
    BrittleJob.performed_attempts = []
  end

  teardown do
    Event.dispatch_after_create = true
  end

  test "a declared transient failure is re-enqueued instead of raising" do
    FlakyJob.perform_now(fail_times: 99)

    assert_equal [ 1 ], FlakyJob.performed_attempts
    assert_enqueued_with job: FlakyJob
  end

  test "a declared transient failure is retried until it succeeds" do
    perform_enqueued_jobs do
      FlakyJob.perform_later(fail_times: 2)
    end

    assert_equal [ 1, 2, 3 ], FlakyJob.performed_attempts
    assert_empty FlakyJob.exhausted
  end

  test "retry exhaustion is bounded and lands in the terminal handler" do
    perform_enqueued_jobs do
      FlakyJob.perform_later(fail_times: 99)
    end

    assert_equal [ 1, 2, 3 ], FlakyJob.performed_attempts
    assert_equal [ TransientError ], FlakyJob.exhausted
  end

  test "an undeclared error raises and is not retried" do
    assert_raises PermanentError do
      BrittleJob.perform_now
    end

    assert_equal [ 1 ], BrittleJob.performed_attempts
    assert_no_enqueued_jobs
  end

  test "a subscriber job whose delivery row is gone is discarded, not parked" do
    Event.dispatch_after_create = false
    order = orders(:keyboard)
    event = order.publish_event("order.paid", item: order.item, quantity: order.quantity)
    delivery = Event::Delivery.create!(event:, subscriber: "Order::ConfirmationJob")
    Order::ConfirmationJob.perform_later(delivery)
    delivery.delete

    assert_nothing_raised do
      perform_enqueued_jobs
    end

    assert_not order.reload.confirmed?
  end
end
