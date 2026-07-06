class Order::ConfirmationJob < ApplicationJob
  queue_as :default

  def perform(event) = Order::Confirmation.record(event)
end
