require "test_helper"
require_relative "../support/google_sign_in_test_helper"
require_relative "../support/quote_terms_test_helper"
require_relative "../support/request_logs_test_helper"

class SecurityBoundariesTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper
  include QuoteTermsTestHelper
  include RequestLogsTestHelper

  test "sign out revokes a captured cookie" do
    sign_in
    get clients_path
    assert_response :success
    captured = cookies["_perfectcrm_session"]
    assert captured.present?

    delete sign_out_path
    assert_redirected_to sign_in_path
    cookies["_perfectcrm_session"] = captured
    get clients_path
    assert_redirected_to sign_in_path
  end

  test "request logs redact customer identity and free text in forms and query strings" do
    sign_in
    logs = capture_request_logs do
      post leads_path, params: { lead: { name: "PrivateSyntheticName", email: "private@example.test",
        message: "PrivateSyntheticMessage", fit_reason: "PrivateSyntheticFitNotes" } }
      assert_response :redirect
      lead = Lead.find_by!(name: "PrivateSyntheticName")
      post lead_messages_path(lead), params: { message: { to: "private@example.test",
        subject: "PrivateSyntheticSubject", body: "PrivateSyntheticBody" } }
      assert_response :redirect
      get leads_path, params: { q: "PrivateSyntheticSearch" }
      assert_response :success
    end
    assert_includes logs, "Processing by LeadsController"
    assert_includes logs, "Parameters:"
    assert_includes logs, "Started GET"
    assert_includes logs, "[FILTERED]"
    %w[PrivateSyntheticName private@example.test PrivateSyntheticMessage PrivateSyntheticFitNotes PrivateSyntheticSearch PrivateSyntheticSubject PrivateSyntheticBody].each do |value|
      assert_not_includes logs, value
    end
  end

  test "public quote logs redact capability paths and redirects while responses remain usable" do
    client = Client.create!(name: "Synthetic quote customer")
    quote = Quote.create!(client: client, status: "sent", sent_at: 1.hour.ago,
      trip_name: "Synthetic journey", valid_until: Date.yesterday)
    logs = capture_request_logs do
      get public_quote_path(quote.accept_token)
      assert_response :success
      post accept_public_quote_path(quote.accept_token)
      assert_redirected_to public_quote_path(quote.accept_token)
      get public_quote_path("unknown-synthetic-capability")
      assert_response :not_found
      delete public_quote_path(quote.accept_token)
      assert_response :not_found
    end
    assert_includes logs, "Started GET"
    assert_includes logs, "Completed 200"
    assert_includes logs, "Redirected to"
    assert_not_includes logs, quote.accept_token
    assert_not_includes logs, "unknown-synthetic-capability"
  end

  test "public quote HTML and documents prohibit storage" do
    quote = Quote.create!(client: Client.create!(name: "Synthetic quote customer", email: "synthetic@example.test"),
      trip_name: "Synthetic journey", valid_until: Date.current + 14)
    quote.lines.create!(description: "Synthetic journey", quantity: 1, unit_minor: 100_000)
    complete_quote_terms(quote)
    assert quote.deliver!, quote.errors.full_messages.to_sentence
    [ public_quote_path(quote.accept_token), public_quote_documents_path(quote.accept_token) ].each do |path|
      get path
      assert_response :success
      assert_includes response.headers.fetch("Cache-Control"), "no-store"
    end
  end

  test "server-side expiry rejects a replay even when the browser resubmits its cookie" do
    sign_in
    captured = cookies["_perfectcrm_session"]
    travel 31.days do
      cookies["_perfectcrm_session"] = captured
      get clients_path
      assert_redirected_to sign_in_path
    end
  end

  test "signing in rotates and revokes the previous session" do
    sign_in
    previous = cookies["_perfectcrm_session"]
    sign_in
    replacement = cookies["_perfectcrm_session"]
    assert_not_equal previous, replacement
    cookies["_perfectcrm_session"] = previous
    get clients_path
    assert_redirected_to sign_in_path
    cookies["_perfectcrm_session"] = replacement
    get clients_path
    assert_response :success
  end

  test "sign out revokes only the current device" do
    sign_in
    first_device = cookies["_perfectcrm_session"]
    cookies.delete("_perfectcrm_session")
    sign_in
    second_device = cookies["_perfectcrm_session"]
    delete sign_out_path

    cookies["_perfectcrm_session"] = first_device
    get clients_path
    assert_response :success
    cookies["_perfectcrm_session"] = second_device
    get clients_path
    assert_redirected_to sign_in_path
  end

  test "CSP enforces nonce-bearing importmaps on sign-in, signed-in pages and public quotes" do
    get sign_in_path
    assert_script_policy
    sign_in
    client = Client.create!(name: "Synthetic quote customer")
    [ root_path, leads_path, clients_path, inbox_path, quotes_path, new_quote_path(client_id: client.id),
      merge_templates_path, edit_settings_path ].each do |path|
      get path
      assert_response :success
      assert_script_policy
    end
    quote = Quote.create!(client: client, status: "sent", sent_at: Time.current)
    get public_quote_path(quote.accept_token)
    assert_response :success
    assert_script_policy
  end

  private

  def assert_script_policy
    policy = response.headers.fetch("Content-Security-Policy")
    assert_nil response.headers["Content-Security-Policy-Report-Only"]
    assert_includes policy, "object-src 'none'"
    assert_includes policy, "base-uri 'none'"
    assert_includes policy, "frame-ancestors 'none'"
    nonce = css_select("meta[name='csp-nonce']").first["content"]
    assert nonce.present?
    assert_includes policy, "'nonce-#{nonce}'"
    assert_select "script[type='importmap'][nonce=?]", nonce
    assert_select "script[type='module'][nonce=?]", nonce
    assert_not_includes policy.split(";").find { |directive| directive.strip.start_with?("script-src ") }, "unsafe-inline"
    assert_select "[onchange], [onclick], [oninput], [onsubmit], [onload]", count: 0
  end
end
