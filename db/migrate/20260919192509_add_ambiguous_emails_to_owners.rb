class AddAmbiguousEmailsToOwners < ActiveRecord::Migration[8.1]
  def change
    add_column :leads, :ambiguous_emails, :text, default: "[]", null: false
    add_column :clients, :ambiguous_emails, :text, default: "[]", null: false
  end
end
