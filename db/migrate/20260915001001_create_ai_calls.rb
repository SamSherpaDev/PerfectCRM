class CreateAiCalls < ActiveRecord::Migration[8.1]
  def change
    create_table :ai_calls do |t|
      t.string :purpose, null: false
      t.string :prompt_version, null: false
      t.string :model
      t.integer :input_tokens
      t.integer :output_tokens
      t.integer :cost_cents, default: 0, null: false
      t.integer :latency_ms
      t.string :status, null: false, default: "ok"
      t.text :request_redacted
      t.text :response_redacted
      t.integer :conversation_id
      t.timestamps
    end
    add_index :ai_calls, :purpose
    add_index :ai_calls, :created_at
    add_index :ai_calls, :conversation_id
  end
end
