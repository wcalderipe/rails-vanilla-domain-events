require "net/smtp"
require "timeout"

class Order::ConfirmationJob < ApplicationJob
  queue_as :default

  # Transient errors specific to this subscriber. The confirmation job owns
  # the mail server, which is the flaky dependency here: a briefly busy or
  # slow SMTP endpoint isn't a reason to stop and wait for a human, just a
  # reason to back off and retry. Deadlocks (transient for every subscriber)
  # are handled in ApplicationJob instead.
  #
  # net/smtp and timeout are required explicitly so their constants are
  # available when retry_on is evaluated. Otherwise ActionMailer would only
  # load net/smtp on the first delivery.
  retry_on Net::SMTPServerBusy, Timeout::Error, wait: :polynomially_longer, attempts: 5

  def perform(event) = Order::Confirmation.record(event)
end
