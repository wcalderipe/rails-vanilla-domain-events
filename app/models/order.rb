class Order < ApplicationRecord
  include Eventable

  has_one :payment, class_name: "Order::Payment", dependent: :destroy
  has_one :shipment, class_name: "Order::Shipment", dependent: :destroy
  has_one :confirmation, class_name: "Order::Confirmation", dependent: :destroy

  validates :customer_email, :item, presence: true
  validates :quantity, numericality: { greater_than: 0 }

  scope :paid, -> { joins(:payment) }
  scope :unpaid, -> { where.missing(:payment) }

  def self.place(customer_email:, item:, quantity: 1)
    transaction do
      order = create!(customer_email:, item:, quantity:)
      order.publish_event("order.placed", item:, quantity:)
      order
    end
  end

  def pay
    transaction do
      create_payment!
      publish_event("order.paid", item:, quantity:, customer_email:)
    end
  end

  def ship
    raise UnpaidOrder if unpaid?

    transaction do
      create_shipment!
      publish_event("order.shipped", item:, quantity:)
    end
  end

  def paid? = payment.present?
  def unpaid? = !paid?
  def shipped? = shipment.present?
  def confirmed? = confirmation.present?

  class UnpaidOrder < StandardError; end
end
