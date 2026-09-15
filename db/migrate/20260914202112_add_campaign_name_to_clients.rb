class AddCampaignNameToClients < ActiveRecord::Migration[8.1]
  def change
    add_column :clients, :campaign_name, :string
  end
end
