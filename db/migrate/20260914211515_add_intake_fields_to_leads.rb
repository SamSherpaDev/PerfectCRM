class AddIntakeFieldsToLeads < ActiveRecord::Migration[8.1]
  def change
    add_column :leads, :phone_raw, :string
    add_column :leads, :trip_handle, :string
    add_column :leads, :trip_title, :string
    add_column :leads, :message, :text
    add_column :leads, :consent_contact_at, :datetime
    add_column :leads, :consent_text_version, :string
    add_column :leads, :placement, :string
    add_column :leads, :travel_month, :integer
    add_column :leads, :travel_year, :integer
    add_column :leads, :timing_unknown, :boolean
    add_column :leads, :party_size, :integer
    add_column :leads, :budget_band, :string
    add_column :leads, :metadata, :text
    add_column :leads, :spam_score, :integer, null: false, default: 0
    add_column :leads, :received_at, :datetime
    add_column :leads, :reference, :string
    add_index :leads, :reference, unique: true, where: "reference IS NOT NULL AND reference != ''"
  end
end
