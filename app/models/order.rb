class Order < ApplicationRecord
  has_one :payment, class_name: "Order::Payment", dependent: :destroy
  has_one :shipment, class_name: "Order::Shipment", dependent: :destroy

  validates :customer_email, :item, presence: true
  validates :quantity, numericality: { greater_than: 0 }

  scope :paid, -> { joins(:payment) }
  scope :unpaid, -> { where.missing(:payment) }

  def self.place(customer_email:, item:, quantity: 1)
    transaction do
      order = create!(customer_email:, item:, quantity:)
      Rails.event.notify("order.placed", order_id: order.id, item:, quantity:)
      order
    end
  end

  def pay
    transaction do
      create_payment!
      Rails.event.notify("order.paid", order_id: id, item:, quantity:, customer_email:)
    end
  end

  def ship
    raise UnpaidOrder if unpaid?

    transaction do
      create_shipment!
      Rails.event.notify("order.shipped", order_id: id, item:, quantity:)
    end
  end

  def paid? = payment.present?
  def unpaid? = !paid?
  def shipped? = shipment.present?

  class UnpaidOrder < StandardError; end
end
