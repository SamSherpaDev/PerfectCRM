class BackfillLeadLastTouch < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      UPDATE leads
      SET last_touch_at = COALESCE(
        (SELECT MAX(contact_at) FROM (
          SELECT notes.created_at AS contact_at FROM notes
          WHERE notes.notable_type = 'Lead' AND notes.notable_id = leads.id
          UNION ALL
          SELECT COALESCE(messages.sent_at, messages.created_at) AS contact_at
          FROM messages INNER JOIN conversations ON conversations.id = messages.conversation_id
          WHERE conversations.linkable_type = 'Lead' AND conversations.linkable_id = leads.id
        )),
        leads.created_at
      )
      WHERE last_touch_at IS NULL
    SQL
  end

  def down
  end
end
