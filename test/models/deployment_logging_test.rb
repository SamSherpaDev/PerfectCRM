require "test_helper"
require "yaml"

class DeploymentLoggingTest < ActiveSupport::TestCase
  test "production compose disables Thruster's unfiltered request logger" do
    compose = YAML.safe_load_file(Rails.root.join("deploy/compose.yml"))
    environment = compose.fetch("services").fetch("app").fetch("environment")

    assert_equal "0", environment.fetch("THRUSTER_LOG_REQUESTS", nil),
      "Thruster request logs bypass Rails filtering of customer data and quote capabilities"
  end
end
