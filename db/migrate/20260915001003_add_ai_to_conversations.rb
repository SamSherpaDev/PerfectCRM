class AddAiToConversations < ActiveRecord::Migration[8.1]
  def change
    add_column :conversations, :ai_summary, :text
    add_column :conversations, :ai_summary_at, :datetime
    add_column :conversations, :ai_triage, :string
    add_column :conversations, :ai_triage_reason, :string
    add_column :conversations, :ai_triage_suggested_source, :string
    add_column :conversations, :ai_triage_at, :datetime
    add_column :conversations, :ai_triage_confirmed, :string
    add_column :conversations, :ai_suggestion_title, :string
    add_column :conversations, :ai_suggestion_due_on, :date
    add_column :conversations, :ai_suggestion_reason, :string
    add_column :conversations, :ai_suggestion_at, :datetime
  end
end
