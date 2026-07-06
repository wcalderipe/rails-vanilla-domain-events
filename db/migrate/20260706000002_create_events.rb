class CreateEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :events do |t|
      t.references :eventable, polymorphic: true, null: false
      t.string :action, null: false
      t.json :payload, null: false, default: {}
      # Outbox marker: nil means the post-commit fanout never completed
      # (crash between commit and enqueue) and the relay must re-dispatch.
      t.datetime :dispatched_at
      t.timestamps
    end

    add_index :events, [ :dispatched_at, :created_at ]
  end
end
