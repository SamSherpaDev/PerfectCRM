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

ActiveRecord::Schema[8.1].define(version: 2026_09_14_183002) do
  create_table "settings", force: :cascade do |t|
    t.string "appearance", default: "paper", null: false
    t.datetime "created_at", null: false
    t.integer "singleton_key", default: 1, null: false
    t.datetime "updated_at", null: false
    t.index ["singleton_key"], name: "index_settings_on_singleton_key", unique: true
    t.check_constraint "singleton_key = 1", name: "settings_singleton"
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
