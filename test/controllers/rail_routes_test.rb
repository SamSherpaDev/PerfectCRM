require "test_helper"
require_relative "../support/google_sign_in_test_helper"

class RailRoutesTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper

  ROUTES = {
    "/" => "Today",
    "/inbox" => "Inbox",
    "/leads" => "Leads",
    "/clients" => "Clients",
    "/pipeline" => "Pipeline",
    "/quotes" => "Quotes",
    "/templates" => "Templates",
    "/settings/edit" => "Settings"
  }.freeze

  test "every rail route renders signed in with its heading" do
    sign_in
    ROUTES.each do |path, heading|
      get path
      assert_response :success, "expected #{path} to render"
      assert_select "h1", heading
    end
  end

  test "every rail route redirects signed out to sign in" do
    ROUTES.each_key do |path|
      get path
      assert_redirected_to sign_in_path, "expected #{path} to require sign in"
    end
  end

  test "health check stays public" do
    get "/up"
    assert_response :success
  end
end
