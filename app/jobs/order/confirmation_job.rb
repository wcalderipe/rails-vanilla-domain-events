require "net/smtp"
require "timeout"

class Order::ConfirmationJob < ApplicationJob
  queue_as :default

  # Retry list for this subscriber only, since it owns the flaky dependency:
  # the mail server. A busy or slow SMTP server should retry, not page a
  # human. Deadlocks are transient for every subscriber, so those live on
  # ApplicationJob instead.
  #
  # net/smtp and timeout are required here so their constants exist when
  # retry_on is evaluated at load time — ActionMailer only loads net/smtp
  # on the first actual delivery.
  retry_on Net::SMTPServerBusy, Timeout::Error, wait: :polynomially_longer, attempts: 5

  def perform(delivery)
    delivery.fulfill { |event| Order::Confirmation.record(event) }
  end
end
