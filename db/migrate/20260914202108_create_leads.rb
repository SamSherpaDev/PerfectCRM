class CreateLeads < ActiveRecord::Migration[8.1]
  def change
    create_table :leads do |t|
      t.string :name, null: false
      t.string :email
      t.string :phone
      t.string :country
      t.string :state
      t.string :kind, null: false, default: "individual"
      t.string :source, null: false, default: "manual"
      t.string :campaign_name
      t.string :external_ref
      t.integer :fit_score
      t.string :fit_band
      t.text :fit_reason
      t.string :status, null: false, default: "new"
      t.references :converted_client, foreign_key: { to_table: :clients }, index: false
      t.datetime :converted_at
      t.references :referred_by_organization, foreign_key: { to_table: :organizations }
      t.integer :perfectbook_contact_id
      t.integer :notes_count, null: false, default: 0
      t.datetime :last_activity_at
      t.timestamps
    end
    add_index :leads, :email, unique: true, where: "email IS NOT NULL AND email != ''"
    add_index :leads, :external_ref, unique: true, where: "external_ref IS NOT NULL AND external_ref != ''"
    add_index :leads, :converted_client_id, unique: true, where: "converted_client_id IS NOT NULL"
    add_index :leads, :perfectbook_contact_id, unique: true, where: "perfectbook_contact_id IS NOT NULL"
    add_index :leads, :status
    add_index :leads, :last_activity_at
  end
end
