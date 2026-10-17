class AddInquiryHeadersToMessages < ActiveRecord::Migration[8.1]
  def change
    add_column :messages, :inquiry_headers, :text
  end
end
