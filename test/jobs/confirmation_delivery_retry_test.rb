require "test_helper"
require "net/smtp"

# The confirmation subscriber's real dependency — the mail server — can
# blink. Chapter 2's thesis is that a subscriber declares its own transient
# errors in retry_on; this exercises that thesis against the REAL
# Order::ConfirmationJob, not a synthetic stand-in.
#
# The transient failure is injected at the delivery boundary (a flaky delivery
# method), so production code carries no test-only seam.
class ConfirmationDeliveryRetryTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  # Stands in for an SMTP server that is briefly busy: fails a controlled
  # number of times, then delivers.
  class FlakyDelivery
    cattr_accessor :remaining_failures, default: 0

    def initialize(_settings) = nil

    def deliver!(mail)
      if self.class.remaining_failures.positive?
        self.class.remaining_failures -= 1
        raise Net::SMTPServerBusy, "451 mail server busy, try later"
      end
      ActionMailer::Base.deliveries << mail
    end
  end

  setup do
    Event.dispatch_after_create = false
    @order = orders(:keyboard)
    ActionMailer::Base.add_delivery_method(:flaky, FlakyDelivery)
    @original_delivery = ActionMailer::Base.delivery_method
    ActionMailer::Base.delivery_method = :flaky
    ActionMailer::Base.deliveries.clear
    FlakyDelivery.remaining_failures = 0
  end

  teardown do
    ActionMailer::Base.delivery_method = @original_delivery
    ActionMailer::Base.deliveries.clear
    FlakyDelivery.remaining_failures = 0
    Event.dispatch_after_create = true
  end

  test "a transient mail failure is retried, not parked, and the email lands exactly once" do
    FlakyDelivery.remaining_failures = 2
    event = @order.publish_event("order.paid", item: @order.item, quantity: @order.quantity)

    perform_enqueued_jobs { event.dispatch }

    assert @order.reload.confirmed?, "the confirmation should be recorded after the transient blips clear"
    assert_equal 1, ActionMailer::Base.deliveries.size, "exactly one confirmation email survives the retries"
    assert_equal @order.customer_email, ActionMailer::Base.deliveries.first.to.first
  end

  test "a redelivered event does not re-send the confirmation email" do
    event = @order.publish_event("order.paid", item: @order.item, quantity: @order.quantity)
    perform_enqueued_jobs { event.dispatch }
    assert_equal 1, ActionMailer::Base.deliveries.size

    # The relay redelivers a fanout it believes was lost (dispatched_at cleared):
    event.update_columns(dispatched_at: nil)
    perform_enqueued_jobs { event.dispatch }

    assert_equal 1, ActionMailer::Base.deliveries.size, "redelivery must not double-send the confirmation email"
  end
end
