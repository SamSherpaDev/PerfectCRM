class AddAiOptOutToRecords < ActiveRecord::Migration[8.1]
  def change
    add_column :clients, :ai_opt_out, :boolean, default: false, null: false
    add_column :leads, :ai_opt_out, :boolean, default: false, null: false
    add_column :organizations, :ai_opt_out, :boolean, default: false, null: false
  end
end
