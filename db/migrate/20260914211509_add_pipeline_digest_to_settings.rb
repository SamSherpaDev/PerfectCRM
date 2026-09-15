class AddPipelineDigestToSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :settings, :pipeline_digest, :boolean, null: false, default: true
  end
end
