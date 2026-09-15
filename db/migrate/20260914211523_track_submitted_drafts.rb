class TrackSubmittedDrafts < ActiveRecord::Migration[8.1]
  def change
    add_column :messages, :submitted_draft_id, :integer
    add_column :messages, :submitted_draft_updated_at, :datetime
  end
end
