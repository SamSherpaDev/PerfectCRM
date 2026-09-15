class CreateLeadsSearchIndex < ActiveRecord::Migration[8.1]
  def change
    execute <<~SQL
      CREATE VIRTUAL TABLE IF NOT EXISTS leads_fts
      USING fts5(name, email, phone_tail, tags, notes, tokenize='porter unicode61');
    SQL
  end

  def down
    execute "DROP TABLE IF EXISTS leads_fts;"
  end
end
