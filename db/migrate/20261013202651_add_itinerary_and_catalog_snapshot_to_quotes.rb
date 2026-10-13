class AddItineraryAndCatalogSnapshotToQuotes < ActiveRecord::Migration[8.1]
  def change
    add_column :quotes, :itinerary, :text
    add_column :quotes, :catalog_snapshot, :json
  end
end
