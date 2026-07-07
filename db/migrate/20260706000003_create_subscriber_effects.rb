class CreateSubscriberEffects < ActiveRecord::Migration[8.1]
  def change
    create_table :order_confirmations do |t|
      # Idempotency by natural key: an order confirms once, no matter how
      # many times the order.paid event is delivered.
      t.references :order, null: false, index: { unique: true }
      t.timestamps
    end

    create_table :inventory_adjustments do |t|
      t.string :item, null: false
      t.integer :delta, null: false
      # Idempotency by event id: the same event applies at most one adjustment.
      t.references :event, null: false, index: { unique: true }
      t.timestamps
    end

    add_index :inventory_adjustments, :item
  end
end
