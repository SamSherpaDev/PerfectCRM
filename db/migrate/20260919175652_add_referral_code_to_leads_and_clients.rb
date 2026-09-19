class AddReferralCodeToLeadsAndClients < ActiveRecord::Migration[8.1]
  def change
    # Advisor referral code from the storefront ?ref= link
    # (attribution.referral_code on sherpa.inquiry.v2). Carried from
    # lead to client at conversion; PerfectBook stays the system of
    # record for commissions. No index: codes are displayed, never queried.
    add_column :leads, :referral_code, :string
    add_column :clients, :referral_code, :string
  end
end
