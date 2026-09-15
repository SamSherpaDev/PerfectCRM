class FixPeopleEmailIndexes < ActiveRecord::Migration[8.1]
  def change
    remove_index :people, :email
    add_index :people, :email
    add_index :people, %i[client_id email], unique: true, where: "client_id IS NOT NULL AND email IS NOT NULL AND email != ''",
      name: "index_people_on_client_and_email"
    add_index :people, %i[lead_id email], unique: true, where: "lead_id IS NOT NULL AND email IS NOT NULL AND email != ''",
      name: "index_people_on_lead_and_email"
  end
end
