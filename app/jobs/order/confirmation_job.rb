require "net/smtp"
require "timeout"

class Order::ConfirmationJob < ApplicationJob
  queue_as :default

  # This subscriber's transient list, declared here because the confirmation
  # owns the dependency that blinks: the mail server. A briefly busy or slow
  # SMTP endpoint is not a reason to park the job for a human — it is a reason
  # to back off and try again. Deadlocks (transient for every subscriber) live
  # on ApplicationJob; these live here, per chapter 2.
  #
  # net/smtp/timeout are required so the constants resolve at load time, when
  # retry_on is evaluated — ActionMailer would otherwise only load net/smtp on
  # the first delivery.
  retry_on Net::SMTPServerBusy, Timeout::Error, wait: :polynomially_longer, attempts: 5

  def perform(event) = Order::Confirmation.record(event)
end
