class AddSourceHistory < ActiveRecord::Migration[8.1]
  def change
    %i[leads clients people].each do |table|
      add_column table, :capture_channel, :string
      add_column table, :reported_source_code, :string
      add_column table, :reported_source_detail, :string
      add_column table, :source_answer_state, :string, null: false, default: "not_asked"
      add_column table, :source_confirmed_at, :datetime
      add_column table, :is_test, :boolean, null: false, default: false
      add_reference table, :origin_lead, foreign_key: { to_table: :leads }
      add_reference table, :referred_by_client, foreign_key: { to_table: :clients }
      add_reference table, :referred_by_person, foreign_key: { to_table: :people }
      add_index table, :reported_source_code
      add_index table, :source_answer_state
    end
    add_reference :leads, :existing_client, foreign_key: { to_table: :clients }
    add_reference :people, :origin_person, foreign_key: { to_table: :people }
    add_column :activity_events, :idempotency_key, :string
    add_index :activity_events, [ :subject_type, :subject_id, :kind, :idempotency_key ], unique: true, name: "index_activity_event_idempotency"
  end
end
