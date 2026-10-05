# Replaces only known stale clauses, including within renamed/edited rows.
# No sent message, quote, draft or accepted booking is rewritten.
class ReconcileStoredTemplatePolicyClauses < ActiveRecord::Migration[8.1]
  class MigrationTemplate < ActiveRecord::Base
    self.table_name = "templates"
  end

  def up
    MigrationTemplate.find_each do |template|
      body = TemplatePolicyRefresh.body(template.body)
      subject = template.subject
      if [ "Your {{trip}} seats are on hold", "Holding your {{trip}} seats with {{deposit_due}}" ].include?(subject)
        subject = "Payment for your {{trip}}"
      end
      next if body == template.body && subject == template.subject

      template.update_columns(body: body, subject: subject, updated_at: Time.current)
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Do not restore superseded payment and safety assurances"
  end
end
