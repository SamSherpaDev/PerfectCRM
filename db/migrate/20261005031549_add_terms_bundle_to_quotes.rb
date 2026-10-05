class AddTermsBundleToQuotes < ActiveRecord::Migration[8.1]
  def change
    add_column :quotes, :journey_kind, :string
    add_column :quotes, :local_operator, :text
    add_column :quotes, :disclosure_details, :json
    add_column :quotes, :trip_differences, :text
    add_column :quotes, :terms_bundle, :json
    add_column :quotes, :terms_bundle_sha256, :string
    add_column :quotes, :accepted_terms_version, :string
    add_column :quotes, :accepted_bundle_sha256, :string
  end
end
