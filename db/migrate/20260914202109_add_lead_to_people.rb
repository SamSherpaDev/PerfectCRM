class AddLeadToPeople < ActiveRecord::Migration[8.1]
  def change
    add_reference :people, :lead, foreign_key: true
    change_column_null :people, :client_id, true
  end
end
