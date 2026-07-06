class Order::Payment < ApplicationRecord
  belongs_to :order, touch: true

  validates :order, uniqueness: true
end
