class CreateAdSpends < ActiveRecord::Migration[8.1]
  def change
    create_table :ad_spends do |t|
      t.date :week_start, null: false
      t.string :source, null: false
      t.string :campaign_name, null: false, default: ""
      t.integer :amount_minor, null: false

      t.timestamps
    end
    add_index :ad_spends, %i[week_start source campaign_name], unique: true
  end
end
