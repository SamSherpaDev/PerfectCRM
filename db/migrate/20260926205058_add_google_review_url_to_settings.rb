class AddGoogleReviewUrlToSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :settings, :google_review_url, :string, default: "", null: false
  end
end
