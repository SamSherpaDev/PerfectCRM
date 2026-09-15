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
end
