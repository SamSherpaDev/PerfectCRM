# frozen_string_literal: true

# Repeat visitors may hold several open inquiries under one address, so the
# partial unique guard on leads.email goes away. Replay dedupe stays on the
# unique external_ref index; the PerfectBook contact link stays unique.
class AllowMultipleOpenLeadsPerEmail < ActiveRecord::Migration[8.1]
  OPEN_EMAIL_WHERE = "email IS NOT NULL AND email != '' AND converted_client_id IS NULL AND status != 'lost' AND archived_at IS NULL"

  def up
    remove_index :leads, name: "index_leads_on_email"
  end

  def down
    add_index :leads, :email, unique: true, where: OPEN_EMAIL_WHERE, name: "index_leads_on_email"
  end
end
