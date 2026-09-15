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

ActiveRecord::Schema[8.1].define(version: 2026_09_14_202008) do
  create_table "perfectbook_bookings", force: :cascade do |t|
    t.integer "balance_due_minor"
    t.datetime "created_at", null: false
    t.string "currency", default: "USD"
    t.string "deep_link"
    t.integer "departure_id"
    t.string "departure_place"
    t.date "end_date"
    t.string "invoice_badge"
    t.string "invoice_number"
    t.integer "paid_minor"
    t.integer "party_size"
    t.string "payment_reference"
    t.integer "perfectbook_contact_id", null: false
    t.integer "perfectbook_id", null: false
    t.integer "price_per_person_minor"
    t.string "ref"
    t.date "start_date"
    t.string "status"
    t.datetime "synced_at", null: false
    t.integer "total_minor"
    t.integer "trip_id"
    t.string "trip_name"
    t.datetime "updated_at", null: false
    t.index ["perfectbook_contact_id"], name: "index_perfectbook_bookings_on_perfectbook_contact_id"
    t.index ["perfectbook_id"], name: "index_perfectbook_bookings_on_perfectbook_id", unique: true
  end

  create_table "perfectbook_contacts", force: :cascade do |t|
    t.boolean "archived", default: false, null: false
    t.string "country"
    t.datetime "created_at", null: false
    t.string "email"
    t.string "kind"
    t.string "name"
    t.datetime "pb_created_at"
    t.datetime "pb_updated_at"
    t.integer "perfectbook_id", null: false
    t.string "phone"
    t.string "state"
    t.datetime "synced_at", null: false
    t.datetime "updated_at", null: false
    t.index ["kind"], name: "index_perfectbook_contacts_on_kind"
    t.index ["perfectbook_id"], name: "index_perfectbook_contacts_on_perfectbook_id", unique: true
  end

  create_table "perfectbook_departures", force: :cascade do |t|
    t.integer "available_seats"
    t.integer "booked_seats"
    t.text "country_codes"
    t.datetime "created_at", null: false
    t.string "currency", default: "USD"
    t.integer "duration_days"
    t.date "end_date"
    t.string "label"
    t.datetime "pb_created_at"
    t.datetime "pb_updated_at"
    t.integer "perfectbook_id", null: false
    t.integer "perfectbook_trip_id"
    t.string "place"
    t.integer "price_per_person_minor"
    t.integer "seats"
    t.date "start_date"
    t.string "status"
    t.datetime "synced_at", null: false
    t.string "trip_name"
    t.datetime "updated_at", null: false
    t.index ["perfectbook_id"], name: "index_perfectbook_departures_on_perfectbook_id", unique: true
    t.index ["perfectbook_trip_id"], name: "index_perfectbook_departures_on_perfectbook_trip_id"
  end

  create_table "perfectbook_etag_stores", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "etag", null: false
    t.string "key", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_perfectbook_etag_stores_on_key", unique: true
  end

  create_table "perfectbook_sync_states", force: :cascade do |t|
    t.bigint "contact_cursor"
    t.datetime "created_at", null: false
    t.string "job_name", null: false
    t.text "last_error"
    t.datetime "last_error_at"
    t.datetime "last_success_at"
    t.datetime "updated_at", null: false
    t.index ["job_name"], name: "index_perfectbook_sync_states_on_job_name", unique: true
  end

  create_table "perfectbook_trips", force: :cascade do |t|
    t.boolean "active", default: false, null: false
    t.datetime "created_at", null: false
    t.text "departure_ids"
    t.integer "departures_count", default: 0
    t.date "first_start_date"
    t.date "last_end_date"
    t.string "name", null: false
    t.datetime "pb_created_at"
    t.datetime "pb_updated_at"
    t.integer "perfectbook_id", null: false
    t.string "shopify_product_id"
    t.string "status"
    t.datetime "synced_at", null: false
    t.datetime "updated_at", null: false
    t.index ["perfectbook_id"], name: "index_perfectbook_trips_on_perfectbook_id", unique: true
  end

  create_table "settings", force: :cascade do |t|
    t.string "appearance", default: "paper", null: false
    t.datetime "created_at", null: false
    t.integer "singleton_key", default: 1, null: false
    t.datetime "updated_at", null: false
    t.index ["singleton_key"], name: "index_settings_on_singleton_key", unique: true
    t.check_constraint "singleton_key = 1", name: "settings_singleton"
  end

  create_table "templates", force: :cascade do |t|
    t.datetime "archived_at"
    t.text "body", default: "", null: false
    t.string "channel", default: "email", null: false
    t.datetime "created_at", null: false
    t.datetime "last_used_at"
    t.string "name", null: false
    t.integer "position", default: 0, null: false
    t.integer "purpose", default: 8, null: false
    t.string "subject", default: "", null: false
    t.datetime "updated_at", null: false
    t.integer "usage_count", default: 0, null: false
    t.index ["archived_at"], name: "index_templates_on_archived_at"
    t.index ["position"], name: "index_templates_on_position"
    t.index ["purpose"], name: "index_templates_on_purpose"
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.string "google_sub", null: false
    t.datetime "last_signed_in_at"
    t.string "name"
    t.datetime "updated_at", null: false
    t.index ["google_sub"], name: "index_users_on_google_sub", unique: true
  end
end
