require "test_helper"
require_relative "../support/google_sign_in_test_helper"

class MailImportsRequestsTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper

  setup do
    sign_in
  end

  test "new import renders scope choices without a 90-day cap" do
    get new_mail_import_path
    assert_response :success
    assert_select "select[name='mail_import[scope]']"
    assert_match(/no 90-day cap/i, response.body)
  end

  test "new import redirects to a working preview and enqueues scanning" do
    assert_enqueued_jobs 1, only: Mail::PreviewJob do
      post mail_imports_path, params: { mail_import: { scope: "all" } }
    end
    assert_response :see_other
    follow_redirect!
    assert_response :success
    assert_select "p", text: /Scanning history/
    assert_select "input[value='Commit import']", count: 0
  end

  test "completed preview can be committed only once" do
    import = MailImport.create!(scope: "all", status: "preview", preview_json: { "rows" => [] })
    get preview_mail_import_path(import)
    assert_response :success
    assert_enqueued_jobs 1, only: Mail::ImportJob do
      post commit_mail_import_path(import)
      post commit_mail_import_path(import)
    end
    assert_redirected_to mail_import_path(import)
  end
  test "selected range validates inputs and ignores stale values from other modes" do
    [ { scope: "since_date", since_date: "" }, { scope: "last_n_months", months: "" }, { scope: "last_n_months", months: "0" } ].each do |attributes|
      assert_no_difference("MailImport.count") { post mail_imports_path, params: { mail_import: attributes } }
      assert_response :unprocessable_entity
    end
    travel_to Time.zone.local(2026, 9, 14) do
      post mail_imports_path, params: { mail_import: { scope: "last_n_months", months: 12, since_date: "2020-01-01" } }
      assert_response :see_other
      import = MailImport.order(:id).last
      assert_equal Date.new(2025, 9, 14), import.cutoff_date
      travel 2.months
      assert_equal Date.new(2025, 9, 14), import.reload.cutoff_date
    end
  end

  test "commit stores the captain choice instead of the preview suggestion" do
    import = MailImport.create!(scope: "all", status: "preview", preview_json: {
      "rows" => [ { "email" => "solo@example.com", "count" => 1, "suggested_kind" => "client" } ]
    })
    assert_enqueued_jobs 1, only: Mail::ImportJob do
      post commit_mail_import_path(import), params: { choices: { "solo@example.com" => "organization" } }
    end
    assert_equal "organization", import.reload.preview_json["choices"]["solo@example.com"]
  end
end
