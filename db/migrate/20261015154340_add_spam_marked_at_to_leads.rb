class AddSpamMarkedAtToLeads < ActiveRecord::Migration[8.1]
  def change
    add_column :leads, :spam_marked_at, :datetime
  end
end
