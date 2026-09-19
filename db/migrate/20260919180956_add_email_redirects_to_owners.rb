class AddEmailRedirectsToOwners < ActiveRecord::Migration[8.1]
  def change
    add_column :leads, :email_redirects, :text, default: "{}", null: false
    add_column :clients, :email_redirects, :text, default: "{}", null: false
  end
end
