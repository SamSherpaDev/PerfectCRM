require "test_helper"
require_relative "../support/google_sign_in_test_helper"

# Correction A: sample data appears only in the labeled editor preview.
# The picker, the one-tap use endpoint, and the merge preview render live
# values only — everything else is a visible [missing: …] marker.
class TemplateOperationalRenderingTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper

  setup do
    @template = Template.create!(name: "Deposit nudge", purpose: "deposit_nudge",
      subject: "Your {{trip}} deposit", body: "Hi {{first_name}}, {{balance_due}} please.")
  end

  test "picker json marks unknown values instead of sampling them" do
    sign_in
    get picker_templates_path(format: :json)
    assert_response :success
    row = response.parsed_body.find { |entry| entry["id"] == @template.id }
    assert_match(/\[missing: first_name\]/, row["body"])
    assert_no_match(/Maya/, row["body"])
  end

  test "picker json fills values the caller passes" do
    sign_in
    get picker_templates_path(format: :json), params: { context: { first_name: "Tashi" } }
    row = response.parsed_body.find { |entry| entry["id"] == @template.id }
    assert_match(/Hi Tashi/, row["body"])
    assert_match(/\[missing: balance_due\]/, row["body"])
  end

  test "use endpoint never samples" do
    sign_in
    post use_template_path(@template, format: :json)
    assert_response :success
    assert_match(/\[missing: first_name\]/, response.parsed_body["body"])
  end

  test "editor preview still shows labeled sample data" do
    sign_in
    post preview_templates_path, params: { template: { subject: "Hi", body: "Hi {{first_name}}" } }
    assert_response :success
    assert_match(/Maya/, response.body)
  end
end
