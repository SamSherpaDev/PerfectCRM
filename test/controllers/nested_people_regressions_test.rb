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

  test "linked person removal returns form feedback and preserves every source relationship" do
    [ Client, Lead ].each do |owner_model|
      [ Lead, Client, Person, :origin ].each do |referrer_model|
        owner = owner_model.create!(name: "Travelers")
        person = owner.people.create!(name: "Linked traveler")
        attributes = { name: "Source record", referred_by_person: person }
        attributes[:client] = Client.create!(name: "Other owner") if referrer_model == Person
        linked = if referrer_model == :origin
          Person.create!(name: "Copied traveler", client: Client.create!(name: "Converted owner"), origin_person: person)
        else
          referrer_model.create!(**attributes)
        end
        patch polymorphic_path(owner), params: { owner_model.model_name.param_key => {
          name: "Changed", people_attributes: { "0" => { id: person.id, _destroy: "1" } }
        } }
        assert_response :unprocessable_entity
        assert_select "body", text: /this person is linked to source history/
        assert_equal "Travelers", owner.reload.name
        assert Person.exists?(person.id)
        field = referrer_model == :origin ? :origin_person_id : :referred_by_person_id
        assert_equal person.id, linked.reload.public_send(field)
        assert_not person.destroy
        assert_includes person.errors.full_messages, "Cannot remove a person linked to source history"
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

  test "existing people can reassign emails regardless of creation order" do
    [ Client, Lead ].each do |model|
      [ "", "one@example.com" ].each do |second_email|
        record = model.create!(name: "Travelers")
        first = record.people.create!(name: "One", email: "one@example.com")
        second = record.people.create!(name: "Two", email: "two@example.com")
        patch polymorphic_path(record), params: { model.model_name.param_key => {
          people_attributes: {
            "0" => { id: first.id, name: "One", email: "two@example.com" },
            "1" => { id: second.id, name: "Two", email: second_email }
          }
        } }
        assert_response :redirect
        assert_equal "two@example.com", first.reload.email
        if second_email.empty?
          assert_nil second.reload.email
        else
          assert_equal second_email, second.reload.email
        end
        assert_equal 2, record.people.count
      end
    end
  end
end
