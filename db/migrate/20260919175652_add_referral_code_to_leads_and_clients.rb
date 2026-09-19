class AddReferralCodeToLeadsAndClients < ActiveRecord::Migration[8.1]
  def change
    add_column :leads, :referral_code, :string
    add_column :clients, :referral_code, :string
  end
end
