# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_07_07_000001) do
  create_table "event_deliveries", force: :cascade do |t|
    t.integer "attempts", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "delivered_at"
    t.string "error"
    t.integer "event_id", null: false
    t.datetime "failed_at"
    t.string "subscriber", null: false
    t.datetime "updated_at", null: false
    t.index ["event_id", "subscriber"], name: "index_event_deliveries_on_event_id_and_subscriber", unique: true
    t.index ["updated_at"], name: "index_event_deliveries_pending_scan", where: "delivered_at IS NULL AND failed_at IS NULL"
  end

  create_table "events", force: :cascade do |t|
    t.string "action", null: false
    t.datetime "created_at", null: false
    t.datetime "dispatched_at"
    t.integer "eventable_id", null: false
    t.string "eventable_type", null: false
    t.json "payload", default: {}, null: false
    t.datetime "updated_at", null: false
    t.index ["dispatched_at", "created_at"], name: "index_events_on_dispatched_at_and_created_at"
    t.index ["eventable_type", "eventable_id"], name: "index_events_on_eventable"
  end

  create_table "inventory_adjustments", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "delta", null: false
    t.integer "event_id", null: false
    t.string "item", null: false
    t.datetime "updated_at", null: false
    t.index ["event_id"], name: "index_inventory_adjustments_on_event_id", unique: true
    t.index ["item"], name: "index_inventory_adjustments_on_item"
  end

  create_table "order_confirmations", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "order_id", null: false
    t.datetime "updated_at", null: false
    t.index ["order_id"], name: "index_order_confirmations_on_order_id", unique: true
  end

  create_table "order_payments", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "order_id", null: false
    t.datetime "updated_at", null: false
    t.index ["order_id"], name: "index_order_payments_on_order_id", unique: true
  end

  create_table "order_shipments", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "order_id", null: false
    t.datetime "updated_at", null: false
    t.index ["order_id"], name: "index_order_shipments_on_order_id", unique: true
  end

  create_table "orders", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "customer_email", null: false
    t.string "item", null: false
    t.integer "quantity", default: 1, null: false
    t.datetime "updated_at", null: false
  end

  add_foreign_key "event_deliveries", "events"
end
