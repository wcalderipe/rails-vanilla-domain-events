class AddIdempotenceKeyToEvents < ActiveRecord::Migration[8.1]
  def change
    add_column :events, :idempotence_key, :string
    add_index :events, :idempotence_key, unique: true, where: "idempotence_key IS NOT NULL"
  end
end
