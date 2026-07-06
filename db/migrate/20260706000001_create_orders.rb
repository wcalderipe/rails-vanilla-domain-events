class CreateOrders < ActiveRecord::Migration[8.1]
  def change
    create_table :orders do |t|
      t.string :customer_email, null: false
      t.string :item, null: false
      t.integer :quantity, null: false, default: 1
      t.timestamps
    end

    create_table :order_payments do |t|
      t.references :order, null: false, index: { unique: true }
      t.timestamps
    end

    create_table :order_shipments do |t|
      t.references :order, null: false, index: { unique: true }
      t.timestamps
    end
  end
end
