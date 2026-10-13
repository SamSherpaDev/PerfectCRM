class AddShopifyProductIdToQuotes < ActiveRecord::Migration[8.1]
  def change
    add_column :quotes, :shopify_product_id, :string
  end
end
