class AddDigestToSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :settings, :digest_enabled, :boolean, null: false, default: true
  end
end
