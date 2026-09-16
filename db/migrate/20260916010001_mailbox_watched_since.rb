# When the captain first connected the Microsoft 365 mailbox. Live sync
# takes only mail received from then on, in every folder, however late the
# folder appears; anything older is Import history's to bring in at the
# depth he chooses with a preview.
class MailboxWatchedSince < ActiveRecord::Migration[8.1]
  def change
    add_column :settings, :mailbox_watched_since, :datetime
  end
end
