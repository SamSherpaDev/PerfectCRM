require "test_helper"
require "yaml"

class DeploymentLoggingTest < ActiveSupport::TestCase
  test "production compose serves Rails directly on the healthcheck port" do
    compose = YAML.safe_load_file(Rails.root.join("deploy/compose.yml"))
    app = compose.fetch("services").fetch("app")
    environment = app.fetch("environment")

    assert_equal [ "./bin/rails", "server" ], app.fetch("command")
    assert_equal "80", environment.fetch("PORT")
    assert_includes app.fetch("expose"), "80"
  end
end
