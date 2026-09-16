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

ActiveRecord::Schema[8.1].define(version: 2026_09_15_213004) do
  create_table "active_storage_attachments", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.string "key", null: false
    t.text "metadata"
    t.string "service_name", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

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

  create_table "ai_calls", force: :cascade do |t|
    t.integer "conversation_id"
    t.integer "cost_micro_cents", default: 0, null: false
    t.datetime "created_at", null: false
    t.integer "input_tokens"
    t.integer "latency_ms"
    t.string "model"
    t.integer "output_tokens"
    t.string "prompt_version", null: false
    t.string "purpose", null: false
    t.text "request_redacted"
    t.text "response_redacted"
    t.string "status", default: "ok", null: false
    t.datetime "updated_at", null: false
    t.index ["conversation_id"], name: "index_ai_calls_on_conversation_id"
    t.index ["created_at"], name: "index_ai_calls_on_created_at"
    t.index ["purpose"], name: "index_ai_calls_on_purpose"
  end

  create_table "clients", force: :cascade do |t|
    t.boolean "ai_opt_out", default: false, null: false
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
    t.string "pipeline_stage", default: "won", null: false
    t.integer "referred_by_organization_id"
    t.string "source"
    t.string "state"
    t.datetime "updated_at", null: false
    t.index ["archived_at"], name: "index_clients_on_archived_at"
    t.index ["email"], name: "index_clients_on_email", unique: true, where: "email IS NOT NULL AND email != ''"
    t.index ["last_activity_at"], name: "index_clients_on_last_activity_at"
    t.index ["perfectbook_contact_id"], name: "index_clients_on_perfectbook_contact_id", unique: true, where: "perfectbook_contact_id IS NOT NULL"
    t.index ["pipeline_stage"], name: "index_clients_on_pipeline_stage"
    t.index ["referred_by_organization_id"], name: "index_clients_on_referred_by_organization_id"
  end

  create_table "conversations", force: :cascade do |t|
    t.datetime "ai_suggestion_at"
    t.date "ai_suggestion_due_on"
    t.string "ai_suggestion_reason"
    t.string "ai_suggestion_title"
    t.text "ai_summary"
    t.datetime "ai_summary_at"
    t.string "ai_triage"
    t.datetime "ai_triage_at"
    t.string "ai_triage_reason"
    t.string "ai_triage_suggested_source"
    t.datetime "created_at", null: false
    t.boolean "ignored", default: false, null: false
    t.datetime "last_message_at"
    t.integer "linkable_id"
    t.string "linkable_type"
    t.text "participant_emails", default: "[]", null: false
    t.string "provider_thread_id"
    t.string "subject"
    t.integer "unread_count", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["ignored"], name: "index_conversations_on_ignored"
    t.index ["last_message_at"], name: "index_conversations_on_last_message_at"
    t.index ["linkable_type", "linkable_id"], name: "index_conversations_on_linkable_type_and_linkable_id"
    t.index ["provider_thread_id"], name: "index_conversations_on_provider_thread_id", unique: true, where: "provider_thread_id IS NOT NULL AND provider_thread_id != ''"
  end

  create_table "demo_records", force: :cascade do |t|
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.index ["record_type", "record_id"], name: "index_demo_records_on_record_type_and_record_id", unique: true
  end

  create_table "document_holdings", force: :cascade do |t|
    t.integer "byte_size", default: 0, null: false
    t.string "content_type"
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.string "filename", null: false
    t.integer "message_id", null: false
    t.datetime "updated_at", null: false
    t.index ["expires_at"], name: "index_document_holdings_on_expires_at"
    t.index ["message_id"], name: "index_document_holdings_on_message_id"
  end

  create_table "document_upload_orphans", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "key", null: false
    t.string "service_name", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_document_upload_orphans_on_key", unique: true
  end

  create_table "drafts", force: :cascade do |t|
    t.text "bcc_addrs", default: ""
    t.text "body", default: ""
    t.text "cc_addrs", default: ""
    t.integer "conversation_id"
    t.datetime "created_at", null: false
    t.integer "owner_id", null: false
    t.string "owner_type", null: false
    t.integer "perfectbook_booking_id"
    t.string "subject", default: ""
    t.integer "template_id"
    t.text "to_addrs", default: ""
    t.datetime "updated_at", null: false
    t.index ["conversation_id"], name: "index_drafts_on_conversation_id", unique: true, where: "conversation_id IS NOT NULL"
    t.index ["owner_type", "owner_id"], name: "index_drafts_on_owner_type_and_owner_id"
    t.index ["template_id"], name: "index_drafts_on_template_id"
  end

  create_table "email_identities", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.boolean "ignored", default: false, null: false
    t.datetime "last_confirmed_at"
    t.integer "linkable_id"
    t.string "linkable_type"
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_email_identities_on_email", unique: true
    t.index ["linkable_type", "linkable_id"], name: "index_email_identities_on_linkable_type_and_linkable_id"
  end

  create_table "group_sends", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "perfectbook_departure_id"
    t.text "recipient_lines"
    t.string "status", default: "sending", null: false
    t.integer "template_id", null: false
    t.integer "total_count", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["status"], name: "index_group_sends_on_status"
    t.index ["template_id"], name: "index_group_sends_on_template_id"
  end

  create_table "lead_notifications", force: :cascade do |t|
    t.datetime "available_at", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.datetime "created_at", null: false
    t.datetime "delivered_at"
    t.string "event", null: false
    t.integer "lead_id", null: false
    t.datetime "updated_at", null: false
    t.index ["available_at"], name: "index_lead_notifications_on_available_at", where: "delivered_at IS NULL"
    t.index ["lead_id"], name: "index_lead_notifications_on_lead_id"
  end

  create_table "lead_rate_limit_entries", force: :cascade do |t|
    t.datetime "expires_at", null: false
    t.string "key", null: false
    t.index ["expires_at"], name: "index_lead_rate_limit_entries_on_expires_at"
    t.index ["key"], name: "index_lead_rate_limit_entries_on_key"
  end

  create_table "lead_webhook_deliveries", force: :cascade do |t|
    t.integer "attempts", default: 0, null: false
    t.datetime "created_at", null: false
    t.text "error"
    t.string "event", null: false
    t.integer "http_status"
    t.integer "lead_id"
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.string "url", null: false
    t.index ["created_at"], name: "index_lead_webhook_deliveries_on_created_at"
    t.index ["lead_id"], name: "index_lead_webhook_deliveries_on_lead_id"
  end

  create_table "leads", force: :cascade do |t|
    t.boolean "ai_opt_out", default: false, null: false
    t.string "budget_band"
    t.string "campaign_name"
    t.datetime "consent_contact_at"
    t.string "consent_text_version"
    t.datetime "converted_at"
    t.integer "converted_client_id"
    t.string "country"
    t.datetime "created_at", null: false
    t.string "email"
    t.integer "expected_value_minor"
    t.string "external_ref"
    t.string "fit_band"
    t.text "fit_reason"
    t.integer "fit_score"
    t.string "kind", default: "individual", null: false
    t.datetime "last_activity_at"
    t.datetime "last_touch_at"
    t.text "lost_note"
    t.string "lost_reason"
    t.text "message"
    t.text "metadata"
    t.string "name", null: false
    t.integer "notes_count", default: 0, null: false
    t.integer "party_size"
    t.integer "perfectbook_contact_id"
    t.string "phone"
    t.string "phone_raw"
    t.string "placement"
    t.datetime "received_at"
    t.string "reference"
    t.integer "referred_by_organization_id"
    t.string "source", default: "manual", null: false
    t.integer "spam_score", default: 0, null: false
    t.datetime "stage_changed_at"
    t.string "state"
    t.string "status", default: "new", null: false
    t.boolean "timing_unknown"
    t.integer "travel_month"
    t.integer "travel_year"
    t.string "trip_handle"
    t.string "trip_interest"
    t.string "trip_title"
    t.datetime "updated_at", null: false
    t.index ["converted_client_id"], name: "index_leads_on_converted_client_id"
    t.index ["email"], name: "index_leads_on_email", unique: true, where: "email IS NOT NULL AND email != '' AND converted_client_id IS NULL AND status != 'lost'"
    t.index ["external_ref"], name: "index_leads_on_external_ref", unique: true, where: "external_ref IS NOT NULL AND external_ref != ''"
    t.index ["last_activity_at"], name: "index_leads_on_last_activity_at"
    t.index ["last_touch_at"], name: "index_leads_on_last_touch_at"
    t.index ["perfectbook_contact_id"], name: "index_leads_on_perfectbook_contact_id", unique: true, where: "perfectbook_contact_id IS NOT NULL AND converted_client_id IS NULL AND status != 'lost'"
    t.index ["reference"], name: "index_leads_on_reference", unique: true, where: "reference IS NOT NULL AND reference != ''"
    t.index ["referred_by_organization_id"], name: "index_leads_on_referred_by_organization_id"
    t.index ["status"], name: "index_leads_on_status"
  end

  create_table "mail_imports", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "created_clients", default: 0, null: false
    t.integer "created_organizations", default: 0, null: false
    t.text "error"
    t.datetime "finished_at"
    t.integer "linked_messages", default: 0, null: false
    t.integer "months"
    t.text "preview_json"
    t.integer "processed_messages", default: 0, null: false
    t.string "scope", default: "all", null: false
    t.date "since_date"
    t.integer "skipped_messages", default: 0, null: false
    t.datetime "started_at"
    t.string "status", default: "draft", null: false
    t.integer "total_messages", default: 0, null: false
    t.datetime "updated_at", null: false
  end

  create_table "mail_sync_states", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "delta_link"
    t.string "folder", null: false
    t.text "last_error"
    t.datetime "last_error_at"
    t.text "last_notice"
    t.datetime "last_notice_at"
    t.datetime "last_sync_at"
    t.datetime "updated_at", null: false
    t.index ["folder"], name: "index_mail_sync_states_on_folder", unique: true
  end

  create_table "messages", force: :cascade do |t|
    t.text "attachment_notices"
    t.text "bcc_addrs", default: ""
    t.text "cc_addresses", default: "[]", null: false
    t.integer "conversation_id"
    t.datetime "created_at", null: false
    t.string "direction", default: "in", null: false
    t.string "from_address"
    t.integer "group_send_id"
    t.text "held_attachments", default: "[]", null: false
    t.text "html_body"
    t.string "in_reply_to"
    t.string "message_id"
    t.text "provider_labels", default: "[]", null: false
    t.string "provider_message_id"
    t.integer "raw_size", default: 0, null: false
    t.datetime "read_at"
    t.text "references_text"
    t.text "send_error"
    t.datetime "sent_at"
    t.string "status", default: "received", null: false
    t.string "subject"
    t.integer "submitted_draft_id"
    t.datetime "submitted_draft_updated_at"
    t.integer "template_id"
    t.text "text_body"
    t.text "to_addresses", default: "[]", null: false
    t.datetime "updated_at", null: false
    t.index ["conversation_id", "sent_at"], name: "index_messages_on_conversation_id_and_sent_at"
    t.index ["conversation_id"], name: "index_messages_on_conversation_id"
    t.index ["group_send_id"], name: "index_messages_on_group_send_id"
    t.index ["message_id"], name: "index_messages_on_message_id"
    t.index ["provider_message_id"], name: "index_messages_on_provider_message_id", unique: true, where: "provider_message_id IS NOT NULL AND provider_message_id != ''"
    t.index ["status"], name: "index_messages_on_status"
    t.index ["template_id"], name: "index_messages_on_template_id"
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
    t.boolean "ai_opt_out", default: false, null: false
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
    t.text "checklist_json", default: "[]", null: false
    t.datetime "created_at", null: false
    t.string "currency", default: "USD"
    t.string "deep_link"
    t.integer "departure_id"
    t.string "departure_place"
    t.text "documents_json", default: "{}", null: false
    t.date "end_date"
    t.string "invoice_badge"
    t.string "invoice_number"
    t.integer "missing_count", default: 0, null: false
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

  create_table "quote_lines", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "description", null: false
    t.string "kind", default: "custom", null: false
    t.integer "perfectbook_departure_id"
    t.integer "perfectbook_trip_id"
    t.integer "position", default: 0, null: false
    t.integer "quantity", default: 1, null: false
    t.integer "quote_id", null: false
    t.string "snapshot_departure_label"
    t.date "snapshot_end_on"
    t.date "snapshot_start_on"
    t.string "snapshot_trip_name"
    t.integer "total_minor", default: 0, null: false
    t.integer "unit_minor", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["quote_id"], name: "index_quote_lines_on_quote_id"
  end

  create_table "quote_trip_preferences", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "included"
    t.integer "perfectbook_trip_id", null: false
    t.datetime "updated_at", null: false
    t.index ["perfectbook_trip_id"], name: "index_quote_trip_preferences_on_perfectbook_trip_id", unique: true
  end

  create_table "quote_views", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "ip_digest", null: false
    t.integer "quote_id", null: false
    t.datetime "updated_at", null: false
    t.index ["quote_id", "created_at"], name: "index_quote_views_on_quote_id_and_created_at"
    t.index ["quote_id"], name: "index_quote_views_on_quote_id"
  end

  create_table "quotes", force: :cascade do |t|
    t.string "accept_token", null: false
    t.datetime "accepted_at"
    t.date "balance_due_on"
    t.integer "client_id"
    t.datetime "created_at", null: false
    t.string "currency", default: "USD", null: false
    t.date "departure_end_on"
    t.string "departure_label"
    t.date "departure_start_on"
    t.integer "deposit_minor", default: 0, null: false
    t.text "included"
    t.text "intake_payload"
    t.integer "lead_id"
    t.text "notes"
    t.integer "parent_id"
    t.integer "party_size"
    t.integer "perfectbook_departure_id"
    t.integer "perfectbook_trip_id"
    t.string "reference", null: false
    t.datetime "sent_at"
    t.string "sent_by_email"
    t.string "status", default: "draft", null: false
    t.string "trip_name"
    t.datetime "updated_at", null: false
    t.date "valid_until"
    t.integer "version", default: 1, null: false
    t.integer "view_count", default: 0, null: false
    t.datetime "viewed_at"
    t.index ["accept_token"], name: "index_quotes_on_accept_token", unique: true
    t.index ["client_id"], name: "index_quotes_on_client_id"
    t.index ["lead_id"], name: "index_quotes_on_lead_id"
    t.index ["parent_id"], name: "index_quotes_on_parent_id"
    t.index ["reference"], name: "index_quotes_on_reference", unique: true
    t.index ["status"], name: "index_quotes_on_status"
  end

  create_table "settings", force: :cascade do |t|
    t.string "ai_api_key"
    t.string "ai_base_url"
    t.integer "ai_daily_cost_cap_cents", default: 200, null: false
    t.boolean "ai_enabled", default: true, null: false
    t.string "ai_model"
    t.integer "ai_rate_limit_per_minute", default: 20, null: false
    t.text "ai_voice_guide", default: "", null: false
    t.string "appearance", default: "paper", null: false
    t.datetime "created_at", null: false
    t.boolean "digest_enabled", default: true, null: false
    t.text "email_signature", default: "", null: false
    t.string "lead_webhook_url"
    t.text "mailbox_last_error"
    t.datetime "mailbox_last_error_at"
    t.datetime "mailbox_last_sync_at"
    t.text "ms_graph_refresh_token"
    t.boolean "pipeline_digest", default: true, null: false
    t.datetime "relay_last_used_at"
    t.text "relay_secret"
    t.string "sender_name", default: "", null: false
    t.integer "singleton_key", default: 1, null: false
    t.string "site_key"
    t.datetime "site_key_last_used_at"
    t.datetime "updated_at", null: false
    t.index ["singleton_key"], name: "index_settings_on_singleton_key", unique: true
    t.index ["site_key"], name: "index_settings_on_site_key", unique: true, where: "site_key IS NOT NULL AND site_key != ''"
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

  create_table "tasks", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "created_by", default: "captain", null: false
    t.datetime "done_at"
    t.datetime "due_at"
    t.date "due_on", null: false
    t.string "idempotency_key"
    t.string "kind", default: "follow_up", null: false
    t.text "notes"
    t.date "snoozed_until"
    t.integer "subject_id", null: false
    t.string "subject_type", null: false
    t.integer "template_id"
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["done_at"], name: "index_tasks_on_done_at"
    t.index ["due_on"], name: "index_tasks_on_due_on"
    t.index ["idempotency_key"], name: "index_tasks_on_idempotency_key", unique: true, where: "idempotency_key IS NOT NULL AND idempotency_key != ''"
    t.index ["subject_type", "subject_id"], name: "index_tasks_on_subject_type_and_subject_id"
    t.index ["template_id"], name: "index_tasks_on_template_id"
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

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "clients", "organizations", column: "referred_by_organization_id"
  add_foreign_key "drafts", "conversations"
  add_foreign_key "drafts", "templates"
  add_foreign_key "group_sends", "templates"
  add_foreign_key "lead_notifications", "leads"
  add_foreign_key "lead_webhook_deliveries", "leads"
  add_foreign_key "leads", "clients", column: "converted_client_id"
  add_foreign_key "leads", "organizations", column: "referred_by_organization_id"
  add_foreign_key "messages", "conversations"
  add_foreign_key "messages", "group_sends"
  add_foreign_key "messages", "templates"
  add_foreign_key "notes", "users", column: "author_id"
  add_foreign_key "people", "clients"
  add_foreign_key "people", "leads"
  add_foreign_key "quote_lines", "quotes"
  add_foreign_key "quote_views", "quotes"
  add_foreign_key "quotes", "clients"
  add_foreign_key "quotes", "leads"
  add_foreign_key "quotes", "quotes", column: "parent_id"
  add_foreign_key "taggings", "tags"
  add_foreign_key "tasks", "templates"

  # Virtual tables defined in this database.
  # Note that virtual tables may not work with other database engines. Be careful if changing database.
  create_virtual_table "clients_fts", "fts5", ["name", "email", "phone_tail", "tags", "notes", "tokenize='porter unicode61'"]
  create_virtual_table "leads_fts", "fts5", ["name", "email", "phone_tail", "tags", "notes", "tokenize='porter unicode61'"]
  create_virtual_table "organizations_fts", "fts5", ["name", "email", "phone_tail", "tags", "notes", "tokenize='porter unicode61'"]
end
