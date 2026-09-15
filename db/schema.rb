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

ActiveRecord::Schema[8.1].define(version: 2026_09_14_202112) do
  create_table "activity_events", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "kind", null: false
    t.text "metadata"
    t.datetime "occurred_at", null: false
    t.integer "subject_id", null: false
    t.string "subject_type", null: false
    t.string "summary", null: false
    t.datetime "updated_at", null: false
    t.index ["occurred_at"], name: "index_activity_events_on_occurred_at"
    t.index ["subject_type", "subject_id"], name: "index_activity_events_on_subject_type_and_subject_id"
  end

  create_table "clients", force: :cascade do |t|
    t.datetime "archived_at"
    t.string "campaign_name"
    t.string "country"
    t.datetime "created_at", null: false
    t.string "email"
    t.string "kind", default: "individual", null: false
    t.datetime "last_activity_at"
    t.string "name", null: false
    t.integer "notes_count", default: 0, null: false
    t.integer "perfectbook_contact_id"
    t.string "phone"
    t.integer "referred_by_organization_id"
    t.string "source"
    t.string "state"
    t.datetime "updated_at", null: false
    t.index ["archived_at"], name: "index_clients_on_archived_at"
    t.index ["email"], name: "index_clients_on_email", unique: true, where: "email IS NOT NULL AND email != ''"
    t.index ["last_activity_at"], name: "index_clients_on_last_activity_at"
    t.index ["perfectbook_contact_id"], name: "index_clients_on_perfectbook_contact_id", unique: true, where: "perfectbook_contact_id IS NOT NULL"
    t.index ["referred_by_organization_id"], name: "index_clients_on_referred_by_organization_id"
  end

  create_table "leads", force: :cascade do |t|
    t.string "campaign_name"
    t.datetime "converted_at"
    t.integer "converted_client_id"
    t.string "country"
    t.datetime "created_at", null: false
    t.string "email"
    t.string "external_ref"
    t.string "fit_band"
    t.text "fit_reason"
    t.integer "fit_score"
    t.string "kind", default: "individual", null: false
    t.datetime "last_activity_at"
    t.string "name", null: false
    t.integer "notes_count", default: 0, null: false
    t.integer "perfectbook_contact_id"
    t.string "phone"
    t.integer "referred_by_organization_id"
    t.string "source", default: "manual", null: false
    t.string "state"
    t.string "status", default: "new", null: false
    t.datetime "updated_at", null: false
    t.index ["converted_client_id"], name: "index_leads_on_converted_client_id"
    t.index ["email"], name: "index_leads_on_email", unique: true, where: "email IS NOT NULL AND email != '' AND converted_client_id IS NULL AND status != 'lost'"
    t.index ["external_ref"], name: "index_leads_on_external_ref", unique: true, where: "external_ref IS NOT NULL AND external_ref != ''"
    t.index ["last_activity_at"], name: "index_leads_on_last_activity_at"
    t.index ["perfectbook_contact_id"], name: "index_leads_on_perfectbook_contact_id", unique: true, where: "perfectbook_contact_id IS NOT NULL AND converted_client_id IS NULL AND status != 'lost'"
    t.index ["referred_by_organization_id"], name: "index_leads_on_referred_by_organization_id"
    t.index ["status"], name: "index_leads_on_status"
  end

  create_table "notes", force: :cascade do |t|
    t.integer "author_id"
    t.text "body", null: false
    t.datetime "created_at", null: false
    t.integer "notable_id", null: false
    t.string "notable_type", null: false
    t.datetime "updated_at", null: false
    t.index ["author_id"], name: "index_notes_on_author_id"
    t.index ["notable_type", "notable_id"], name: "index_notes_on_notable_type_and_notable_id"
  end

  create_table "organizations", force: :cascade do |t|
    t.string "country"
    t.datetime "created_at", null: false
    t.string "email"
    t.string "kind", default: "other", null: false
    t.datetime "last_activity_at"
    t.string "name", null: false
    t.integer "perfectbook_contact_id"
    t.string "phone"
    t.datetime "updated_at", null: false
    t.string "website"
    t.index ["email"], name: "index_organizations_on_email", unique: true, where: "email IS NOT NULL AND email != ''"
    t.index ["last_activity_at"], name: "index_organizations_on_last_activity_at"
    t.index ["perfectbook_contact_id"], name: "index_organizations_on_perfectbook_contact_id", unique: true, where: "perfectbook_contact_id IS NOT NULL"
  end

  create_table "people", force: :cascade do |t|
    t.integer "client_id"
    t.datetime "created_at", null: false
    t.string "email"
    t.integer "lead_id"
    t.string "name", null: false
    t.string "phone"
    t.string "role"
    t.datetime "updated_at", null: false
    t.index ["client_id", "email"], name: "index_people_on_client_and_email", unique: true, where: "client_id IS NOT NULL AND email IS NOT NULL AND email != ''"
    t.index ["client_id"], name: "index_people_on_client_id"
    t.index ["email"], name: "index_people_on_email"
    t.index ["lead_id", "email"], name: "index_people_on_lead_and_email", unique: true, where: "lead_id IS NOT NULL AND email IS NOT NULL AND email != ''"
    t.index ["lead_id"], name: "index_people_on_lead_id"
  end

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

  create_table "taggings", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "tag_id", null: false
    t.integer "taggable_id", null: false
    t.string "taggable_type", null: false
    t.datetime "updated_at", null: false
    t.index ["tag_id", "taggable_type", "taggable_id"], name: "index_taggings_on_tag_and_taggable", unique: true
    t.index ["tag_id"], name: "index_taggings_on_tag_id"
    t.index ["taggable_type", "taggable_id"], name: "index_taggings_on_taggable_type_and_taggable_id"
  end

  create_table "tags", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_tags_on_name", unique: true
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

  add_foreign_key "clients", "organizations", column: "referred_by_organization_id"
  add_foreign_key "leads", "clients", column: "converted_client_id"
  add_foreign_key "leads", "organizations", column: "referred_by_organization_id"
  add_foreign_key "notes", "users", column: "author_id"
  add_foreign_key "people", "clients"
  add_foreign_key "people", "leads"
  add_foreign_key "taggings", "tags"

  # Virtual tables defined in this database.
  # Note that virtual tables may not work with other database engines. Be careful if changing database.
  create_virtual_table "clients_fts", "fts5", ["name", "email", "phone_tail", "tags", "notes", "tokenize='porter unicode61'"]
  create_virtual_table "leads_fts", "fts5", ["name", "email", "phone_tail", "tags", "notes", "tokenize='porter unicode61'"]
  create_virtual_table "organizations_fts", "fts5", ["name", "email", "phone_tail", "tags", "notes", "tokenize='porter unicode61'"]
end
