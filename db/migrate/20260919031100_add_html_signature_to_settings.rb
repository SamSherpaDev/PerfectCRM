class AddHtmlSignatureToSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :settings, :email_signature_html, :text, default: "", null: false
  end
end
