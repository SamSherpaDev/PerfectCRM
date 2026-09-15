require "test_helper"
require_relative "../support/google_sign_in_test_helper"

class TemplatesRequestsTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper

  setup do
    @template = Template.create!(name: "Deposit nudge", purpose: "deposit_nudge",
      subject: "Your {{trip}} deposit", body: "Hi {{first_name}}, {{deposit_due}} please.")
  end

  test "index groups by purpose with active/archived tabs and counts" do
    sign_in
    get templates_path
    assert_response :success
    assert_select "h1", "Templates"
    assert_select "nav .tab", text: /Active/
    assert_select "nav .tab", text: /Archived/
    assert_select ".tab-count", text: Template.active.count.to_s
    assert_select "h2", "Deposit nudge"
    assert_select "li", text: /Used 0 times · never used/
  end

  test "archived tab lists archived templates with counts" do
    @template.archive!
    sign_in
    get templates_path(tab: "archived")
    assert_response :success
    assert_select "li", text: /Deposit nudge/
    get templates_path
    assert_select "li", text: /Deposit nudge/, count: 0
  end

  test "create saves and redirects with a notice" do
    sign_in
    assert_difference("Template.count") do
      post templates_path, params: { template: { name: "Hello", purpose: "first_reply", subject: "Hi", body: "Hi {{first_name}}" } }
    end
    assert_redirected_to templates_path
    follow_redirect!
    assert_select ".flash-notice", text: /saved/
  end

  test "create rejects blank fields" do
    sign_in
    post templates_path, params: { template: { name: "", body: "" } }
    assert_response :unprocessable_entity
  end

  test "update saves edits" do
    sign_in
    patch template_path(@template), params: { template: { name: "Renamed" } }
    assert_redirected_to templates_path
    assert_equal "Renamed", @template.reload.name
  end

  test "member preview renders the sample context" do
    sign_in
    get preview_template_path(@template)
    assert_response :success
    assert_select "p", text: /Maya/
  end

  test "collection preview renders unsaved form text" do
    sign_in
    post preview_templates_path, params: { template: { subject: "Hey {{first_name}}", body: "Owes {{balance_due}}" } }
    assert_response :success
    assert_match(/Hey Maya/, response.body)
    assert_match(/\$1,850\.00/, response.body)
  end

  test "collection preview badges unknown placeholders" do
    sign_in
    post preview_templates_path, params: { template: { subject: "", body: "Hi {{nicknam}}" } }
    assert_response :success
    assert_match(/\[missing: nicknam\]|Missing: nicknam/, response.body)
  end

  test "duplicate copies with a fresh counter" do
    @template.record_use!
    sign_in
    assert_difference("Template.count") do
      post duplicate_template_path(@template)
    end
    copy = Template.order(:created_at).last
    assert_equal "#{@template.name} (copy)", copy.name
    assert_equal 0, copy.usage_count
    assert_nil copy.last_used_at
    assert_redirected_to edit_template_path(copy)
  end

  test "archive and unarchive move templates between tabs" do
    sign_in
    patch archive_template_path(@template)
    assert @template.reload.archived?
    assert_redirected_to templates_path
    patch unarchive_template_path(@template)
    assert_not @template.reload.archived?
  end

  test "move reorders within the purpose" do
    other = Template.create!(name: "Second", purpose: "deposit_nudge", body: "b")
    sign_in
    patch move_template_path(other, direction: "up")
    assert_redirected_to templates_path
    assert_equal [ other.id, @template.id ], Template.active.for_purpose("deposit_nudge").ordered.map(&:id)
  end

  test "use counts the insert and returns rendered text as JSON" do
    sign_in
    post use_template_path(@template, format: :json)
    assert_response :success
    assert_equal 1, @template.reload.usage_count
    assert_not_nil @template.last_used_at
    payload = JSON.parse(response.body)
    assert_equal "Your Everest Base Camp trek deposit", payload["subject"]
    assert_match(/Hi Maya/, payload["body"])
  end

  test "picker page renders the embeddable list" do
    sign_in
    get picker_templates_path
    assert_response :success
    assert_select "turbo-frame#template_picker"
    assert_select "button", text: "Insert"
  end

  test "picker JSON searches and returns rendered subject and body" do
    Template.create!(name: "Review ask", purpose: "review_ask", subject: "Welcome home", body: "How was {{trip}}?")
    sign_in
    get picker_templates_path(format: :json, q: "review")
    assert_response :success
    payload = JSON.parse(response.body)
    assert_equal 1, payload.size
    assert_equal "Welcome home", payload.first["subject"]
    assert_match(/Everest Base Camp trek/, payload.first["body"])
  end

  test "picker JSON accepts caller context overrides" do
    sign_in
    get picker_templates_path(format: :json, context: { first_name: "Tashi" })
    assert_response :success
    assert_match(/Tashi/, JSON.parse(response.body).first["body"])
  end

  test "merge screen picks a template and previews each rendered message" do
    sign_in
    get merge_templates_path
    assert_response :success
    assert_select "h1", "Merge preview"
    post merge_templates_path, params: { template_id: @template.id,
      recipients: "Maya Gurung <maya@example.com>\npemba@example.com" }
    assert_response :success
    assert_select "li", text: /maya@example.com/
    assert_select "li", text: /pemba@example.com/
    assert_select "p", text: /Hi Maya/
    assert_select ".badge", text: /Nothing sent/
  end

  test "merge preview without recipients asks for emails and sends nothing" do
    sign_in
    post merge_templates_path, params: { template_id: @template.id, recipients: "   " }
    assert_response :success
    assert_select ".flash-alert", text: /at least one recipient/
  end

  test "every template page requires sign in" do
    get templates_path
    assert_redirected_to sign_in_path
    get new_template_path
    assert_redirected_to sign_in_path
    get edit_template_path(@template)
    assert_redirected_to sign_in_path
    get picker_templates_path
    assert_redirected_to sign_in_path
    get merge_templates_path
    assert_redirected_to sign_in_path
    post preview_templates_path, params: { template: { body: "x" } }
    assert_redirected_to sign_in_path
  end
end
