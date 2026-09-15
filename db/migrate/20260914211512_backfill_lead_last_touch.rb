class BackfillLeadLastTouch < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      UPDATE leads
      SET last_touch_at = COALESCE(
        (SELECT MAX(notes.created_at) FROM notes
         WHERE notes.notable_type = 'Lead' AND notes.notable_id = leads.id),
        leads.created_at
      )
      WHERE last_touch_at IS NULL
    SQL
  end

  def down
  end
end
