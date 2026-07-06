# Read model over adjustments: stock is derived from the applied events, so
# replays (which dedupe by event) can never double-count.
module Inventory
  STARTING_STOCK = 100

  def self.on_hand(item)
    STARTING_STOCK + Adjustment.where(item:).sum(:delta)
  end
end
