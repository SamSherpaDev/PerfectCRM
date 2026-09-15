class AddAttachmentNoticesToMessages < ActiveRecord::Migration[8.1]
  def change
    add_column :messages, :attachment_notices, :text
  end
end
