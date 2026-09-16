require "test_helper"
require_relative "../support/google_sign_in_test_helper"
require_relative "../support/graph_fake"

class MailboxSettingsTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper

  setup do
    sign_in
  end

  test "settings shows the fixed mailbox address and connect button" do
    get edit_settings_path
    assert_response :success
    assert_select "h2", text: "Mailbox"
    assert_match Mail.mailbox_address, response.body
    assert_match(/Connect mailbox/, response.body)
    assert_no_match(/App passwords/, response.body)
  end

  # The rendered page is the contract the browser acts on, and Turbo's
  # documented opt-out is what makes the browser submit natively. Without it
  # Turbo Drive follows the cross-origin 302 below with fetch, CORS rejects
  # it, and the one button that connects the mailbox does nothing at all.
  test "both mailbox connect buttons opt out of Turbo so the browser navigates" do
    get edit_settings_path
    assert_select "form[action=?]", mailbox_connect_settings_path do
      assert_select "[data-turbo='false']", count: 1
    end

    Setting.current.update!(ms_graph_refresh_token: "refresh-9", mailbox_watched_since: Time.current)
    get edit_settings_path
    assert_select "form[action=?]", mailbox_connect_settings_path do
      assert_select "[data-turbo='false']", count: 1
    end
  end

  test "connect redirects to Microsoft with the delegated scopes" do
    post mailbox_connect_settings_path
    assert_response :redirect
    location = response.headers["Location"]
    assert_match %r{\Ahttps://login\.microsoftonline\.com/}, location
    query = URI.decode_www_form(URI.parse(location).query).to_h
    assert_includes query["scope"].split, "Mail.Read"
    assert_includes query["scope"].split, "offline_access"
    assert_equal microsoft_callback_url, query["redirect_uri"]
    assert session[:microsoft_auth_state].present?
  end

  test "connected settings show status, test, and reconnect" do
    Setting.current.update!(ms_graph_refresh_token: "refresh-9", mailbox_watched_since: Time.current)
    get edit_settings_path
    assert_response :success
    assert_match(/Connected/, response.body)
    assert_match(/Reconnect mailbox/, response.body)
  end

  # The stored refresh token outlives the grant Microsoft revoked, so the
  # badge has to follow the error the sync recorded, not the token alone.
  test "a revoked grant met by sync shows Reconnect needed instead of Connected" do
    mailbox = FakeMailbox.new
    Setting.current.update!(ms_graph_refresh_token: "refresh-0", mailbox_watched_since: Time.current.change(usec: 0),
      mailbox_last_error: nil, mailbox_last_error_at: nil)
    mailbox.refuse_grant!
    assert_equal false, Mail::SyncJob.new.perform(fetcher: Mail::GraphFetcher.new(transport: mailbox.transport))

    get edit_settings_path
    assert_response :success
    assert_select "#mailbox-heading + p + dl .badge" do |badges|
      assert_equal [ "Reconnect needed" ], badges.map { |badge| badge.text.strip }
    end
    assert_match(/Reconnect mailbox/, response.body)

    mailbox.transport.on_post("oauth2/v2.0/token") do |_url, _params|
      { status: 200, json: { "access_token" => "access-new", "refresh_token" => "refresh-new", "expires_in" => 3600 } }
    end
    Mail::SyncJob.new.perform(fetcher: Mail::GraphFetcher.new(transport: mailbox.transport))
    get edit_settings_path
    assert_select "#mailbox-heading + p + dl .badge" do |badges|
      assert_equal [ "Connected" ], badges.map { |badge| badge.text.strip }
    end
  end

  test "mailbox test without a grant asks to connect" do
    Setting.current.update!(ms_graph_refresh_token: nil)
    post mailbox_test_settings_path
    assert_redirected_to edit_settings_path
    assert_match(/Connect the mailbox/i, flash[:alert].to_s)
  end

  test "mailbox test with a revoked grant asks to reconnect" do
    Setting.current.update!(ms_graph_refresh_token: "refresh-stale")
    Mail::GraphFetcher.stub(:new, ->(*) {
      fetcher = Object.new
      fetcher.define_singleton_method(:test_connection) { raise Mail::GrantRevokedError, "revoked" }
      fetcher
    }) do
      post mailbox_test_settings_path
    end
    assert_redirected_to edit_settings_path
    assert_match(/Reconnect the mailbox/i, flash[:alert].to_s)
  end

  # Test connection learns of the revoked grant before the next sync tick,
  # so the card it lands back on must already agree with its alert.
  test "a revoked grant met by Test connection shows Reconnect needed right away" do
    mailbox = FakeMailbox.new
    Setting.current.update!(ms_graph_refresh_token: "refresh-0", mailbox_watched_since: Time.current.change(usec: 0),
      mailbox_last_error: nil, mailbox_last_error_at: nil)
    mailbox.refuse_grant!
    fetcher = Mail::GraphFetcher.new(transport: mailbox.transport)
    Mail::GraphFetcher.stub(:new, fetcher) do
      post mailbox_test_settings_path
    end
    assert_redirected_to edit_settings_path
    assert_match(/Reconnect the mailbox/i, flash[:alert].to_s)

    follow_redirect!
    assert_select "#mailbox-heading + p + dl .badge" do |badges|
      assert_equal [ "Reconnect needed" ], badges.map { |badge| badge.text.strip }
    end
    assert_match(/Reconnect mailbox/, response.body)
  end

  # Microsoft can accept a grant again without a reconnect; a Test connection
  # that proves it must not leave the card saying Reconnect needed.
  test "a working Test connection after a revoked grant shows Connected right away" do
    mailbox = FakeMailbox.new
    Setting.current.update!(ms_graph_refresh_token: "refresh-0", mailbox_watched_since: Time.current.change(usec: 0),
      mailbox_last_error: nil, mailbox_last_error_at: nil)
    mailbox.refuse_grant!
    fetcher = Mail::GraphFetcher.new(transport: mailbox.transport)
    Mail::GraphFetcher.stub(:new, fetcher) do
      post mailbox_test_settings_path
      assert_match(/Reconnect the mailbox/i, flash[:alert].to_s)

      mailbox.transport.on_post("oauth2/v2.0/token") do |_url, _params|
        { status: 200, json: { "access_token" => "access-new", "refresh_token" => "refresh-new", "expires_in" => 3600 } }
      end
      post mailbox_test_settings_path
    end
    assert_redirected_to edit_settings_path
    assert_equal "Mailbox connection works.", flash[:notice]

    follow_redirect!
    assert_select "#mailbox-heading + p + dl .badge" do |badges|
      assert_equal [ "Connected" ], badges.map { |badge| badge.text.strip }
    end
    assert_select "#mailbox-heading + p + dl dd", text: "None"
  end
end
