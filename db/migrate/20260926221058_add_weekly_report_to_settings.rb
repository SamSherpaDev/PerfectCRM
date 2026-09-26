class AddWeeklyReportToSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :settings, :weekly_report_recipient, :string, null: false, default: ""
  end
end
