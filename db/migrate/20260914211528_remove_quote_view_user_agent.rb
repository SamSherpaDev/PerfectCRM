class RemoveQuoteViewUserAgent < ActiveRecord::Migration[8.1]
  def change
    remove_column :quote_views, :user_agent, :string
  end
end
