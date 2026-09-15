require "test_helper"
require "minitest/mock"

class NestedPeopleTest < ActiveSupport::TestCase
  test "email releases and assignments roll back if the owner save fails" do
    [ Client, Lead ].each do |model|
      owner = model.create!(name: "Travelers")
      first = owner.people.create!(name: "One", email: "one@example.com")
      second = owner.people.create!(name: "Two", email: "two@example.com")
      owner.assign_attributes(people_attributes: {
        "0" => { id: first.id, email: "two@example.com" },
        "1" => { id: second.id, email: "one@example.com" }
      })
      owner.stub(:sync_fts!, -> { raise "Search update failed" }) do
        error = assert_raises(RuntimeError) { owner.save! }
        assert_equal "Search update failed", error.message
      end
      assert_equal "one@example.com", first.reload.email
      assert_equal "two@example.com", second.reload.email
    end
  end
end
