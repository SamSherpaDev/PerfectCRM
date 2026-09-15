require "test_helper"
require_relative "../support/google_sign_in_test_helper"

class NestedPeopleRegressionsTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper

  setup { sign_in }

  test "duplicate normalized emails return errors on new owners" do
    [ Client, Lead ].each do |model|
      assert_no_difference -> { model.count + Person.count } do
        post polymorphic_path(model), params: { model.model_name.param_key => {
          name: "Travelers", people_attributes: [
            { name: "One", email: " SAME@example.com " },
            { name: "Two", email: "same@example.com" }
          ]
        } }
        assert_response :unprocessable_entity
      end
    end
  end

  test "pending nested edits cannot introduce duplicate emails" do
    [ Client, Lead ].each do |model|
      record = model.create!(name: "Travelers")
      first = record.people.create!(name: "One", email: "one@example.com")
      second = record.people.create!(name: "Two", email: "two@example.com")
      patch polymorphic_path(record), params: { model.model_name.param_key => {
        people_attributes: [ { id: first.id, email: "new@example.com" }, { id: second.id, email: "NEW@example.com" } ]
      } }
      assert_response :unprocessable_entity
      assert_equal "one@example.com", first.reload.email
      assert_equal "two@example.com", second.reload.email
    end
  end
end

class NestedPeopleReplacementTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper

  setup { sign_in }

  test "a removed person can be replaced with the same email" do
    [ Client, Lead ].each do |model|
      record = model.create!(name: "Travelers")
      original = record.people.create!(name: "Original", email: "same@example.com")
      patch polymorphic_path(record), params: { model.model_name.param_key => {
        people_attributes: { "0" => { id: original.id, _destroy: "1" }, "1" => { name: "Replacement", email: " SAME@example.com " } }
      } }
      assert_response :redirect
      assert_equal [ [ "Replacement", "same@example.com" ] ], record.people.reload.pluck(:name, :email)
      assert_not Person.exists?(original.id)
    end
  end
  test "a new person can use an email released by a pending edit" do
    [ Client, Lead ].each do |model|
      [ "", "changed@example.com" ].each do |replacement_email|
        record = model.create!(name: "Travelers")
        original = record.people.create!(name: "Original", email: "same@example.com")
        patch polymorphic_path(record), params: { model.model_name.param_key => {
          people_attributes: {
            "0" => { id: original.id, name: "Original", email: replacement_email },
            "1" => { name: "New traveler", email: " SAME@example.com " }
          }
        } }
        assert_response :redirect
        if replacement_email.empty?
          assert_nil original.reload.email
        else
          assert_equal replacement_email, original.reload.email
        end
        assert_equal [ "same@example.com" ], record.people.where(name: "New traveler").pluck(:email)
        assert_equal 2, record.people.count
      end
    end
  end

end
