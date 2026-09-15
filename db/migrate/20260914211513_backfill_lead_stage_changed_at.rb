class BackfillLeadStageChangedAt < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      UPDATE leads
      SET stage_changed_at = updated_at
      WHERE stage_changed_at IS NULL
    SQL
  end

  def down
  end
end
