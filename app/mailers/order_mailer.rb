class OrderMailer < ApplicationMailer
  # The customer-facing side of a confirmed order. Delivering mail is external
  # IO: it can time out or hit a briefly-busy server. That transient is what
  # Order::ConfirmationJob declares in retry_on (chapter 2).
  def confirmation(order)
    mail(
      to: order.customer_email,
      subject: "Your order is confirmed",
      body: "Your order for #{order.item} (qty #{order.quantity}) is confirmed."
    )
  end
end
