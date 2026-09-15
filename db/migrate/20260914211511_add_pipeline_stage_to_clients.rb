class AddPipelineStageToClients < ActiveRecord::Migration[8.1]
  def change
    add_column :clients, :pipeline_stage, :string, null: false, default: "won"
    add_index :clients, :pipeline_stage
  end
end
