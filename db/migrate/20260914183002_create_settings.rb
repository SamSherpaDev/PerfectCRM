class CreateSettings < ActiveRecord::Migration[8.1]
  def change
    create_table :settings do |t|
      t.string :appearance, null: false, default: "paper"
      t.integer :singleton_key, null: false, default: 1
      t.timestamps
    end
    add_index :settings, :singleton_key, unique: true
    add_check_constraint :settings, "singleton_key = 1", name: "settings_singleton"
  end
end
