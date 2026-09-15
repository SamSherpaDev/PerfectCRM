class AddAiToSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :settings, :ai_enabled, :boolean, default: true, null: false
    add_column :settings, :ai_provider, :string, default: "openai_compatible"
    add_column :settings, :ai_model, :string
    add_column :settings, :ai_base_url, :string
    add_column :settings, :ai_api_key, :string
    add_column :settings, :ai_voice_guide, :text, default: "", null: false
    add_column :settings, :ai_daily_cost_cap_cents, :integer, default: 200, null: false
    add_column :settings, :ai_rate_limit_per_minute, :integer, default: 20, null: false
  end
end
