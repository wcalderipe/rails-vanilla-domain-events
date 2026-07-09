class OrderMailer < ApplicationMailer
  # Sends the customer-facing confirmation email. Delivering mail is external
  # IO, so it can time out or hit a briefly busy server — that's the
  # transient error Order::ConfirmationJob handles with retry_on.
  def confirmation(order)
    mail(
      to: order.customer_email,
      subject: "Your order is confirmed",
      body: "Your order for #{order.item} (qty #{order.quantity}) is confirmed."
    )
  end
end
