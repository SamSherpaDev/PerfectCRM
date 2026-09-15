# Logged views of the public tap-to-accept page (/q/:token). The controller
# rate-limits off this table (see PublicQuotesController::VIEW_LIMIT).
class CreateQuoteViews < ActiveRecord::Migration[8.1]
  def change
    create_table :quote_views do |t|
      t.references :quote, null: false, foreign_key: true
      t.string :ip_digest, null: false
      t.string :user_agent
      t.timestamps
    end
    add_index :quote_views, %i[quote_id created_at]
  end
end
