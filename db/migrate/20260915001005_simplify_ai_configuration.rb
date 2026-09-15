class SimplifyAiConfiguration < ActiveRecord::Migration[8.1]
  def up
    change_column_default :settings, :ai_enabled, from: false, to: true
    remove_column :settings, :ai_provider
    remove_column :conversations, :ai_triage_confirmed
    rename_column :ai_calls, :cost_cents, :cost_micro_cents
    execute "UPDATE ai_calls SET cost_micro_cents = cost_micro_cents * 1000000"
    execute "DELETE FROM ai_calls WHERE purpose = 'triage_confirm'"
  end

  def down
    execute "UPDATE ai_calls SET cost_micro_cents = cost_micro_cents / 1000000"
    rename_column :ai_calls, :cost_micro_cents, :cost_cents
    add_column :conversations, :ai_triage_confirmed, :string
    add_column :settings, :ai_provider, :string, default: "openai_compatible"
    change_column_default :settings, :ai_enabled, from: true, to: false
  end
end
