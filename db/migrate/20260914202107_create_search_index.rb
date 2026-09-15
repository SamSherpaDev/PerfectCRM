class CreateSearchIndex < ActiveRecord::Migration[8.1]
  def change
    execute <<~SQL
      CREATE VIRTUAL TABLE IF NOT EXISTS clients_fts
      USING fts5(name, email, phone_tail, tags, notes, tokenize='porter unicode61');
    SQL
    execute <<~SQL
      CREATE VIRTUAL TABLE IF NOT EXISTS organizations_fts
      USING fts5(name, email, phone_tail, tags, notes, tokenize='porter unicode61');
    SQL
  end

  def down
    execute "DROP TABLE IF EXISTS clients_fts;"
    execute "DROP TABLE IF EXISTS organizations_fts;"
  end
end
