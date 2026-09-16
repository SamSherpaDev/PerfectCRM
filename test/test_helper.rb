ENV["RAILS_ENV"] ||= "test"
# Microsoft Graph stub credentials: mail tests inject FakeGraphTransport, so
# these only satisfy Mail::GraphAuth.configured?, never real endpoints.
ENV["MS_GRAPH_CLIENT_ID"] ||= "test-client-id"
ENV["MS_GRAPH_CLIENT_SECRET"] ||= "test-client-secret"
ENV["MS_GRAPH_TENANT_ID"] ||= "test-tenant"
require_relative "../config/environment"
require "rails/test_help"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...
  end
end
