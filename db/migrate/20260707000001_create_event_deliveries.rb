class CreateEventDeliveries < ActiveRecord::Migration[8.1]
  def change
    create_table :event_deliveries do |t|
      t.references :event, null: false, foreign_key: true, index: false
      t.string :subscriber, null: false
      t.integer :attempts, null: false, default: 0
      t.datetime :delivered_at
      t.datetime :failed_at
      t.string :error

      t.timestamps

      t.index [ :event_id, :subscriber ], unique: true
      t.index :updated_at, where: "delivered_at IS NULL AND failed_at IS NULL",
              name: "index_event_deliveries_pending_scan"
    end
  end
end
