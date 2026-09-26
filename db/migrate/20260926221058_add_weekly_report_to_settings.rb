class AddWeeklyReportToSettings < ActiveRecord::Migration[8.1]
  def up
    add_column :settings, :weekly_report_enabled, :boolean, null: false, default: true
    add_column :settings, :weekly_report_recipient, :string, null: false, default: ""
    add_column :settings, :travelers_goal, :integer
    # The captain's 2026 goal: 10 travelers booked by Dec 31.
    execute "UPDATE settings SET travelers_goal = 10"
  end

  def down
    remove_column :settings, :travelers_goal
    remove_column :settings, :weekly_report_recipient
    remove_column :settings, :weekly_report_enabled
  end
end
