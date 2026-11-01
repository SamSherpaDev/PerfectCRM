class MoveUnansweredUnsureLeadsToNotInterested < ActiveRecord::Migration[8.1]
  def up
    Lead.reset_column_information
    moved = CallLog.backfill_unanswered_not_interested!
    say "Moved #{moved} Unsure #{'lead'.pluralize(moved)} with three unanswered calls to Not interested"
  end

  def down
  end
end
