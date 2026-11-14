require "test_helper"
require "yaml"

class LitestreamConfigTest < ActiveSupport::TestCase
  # Litestream 0.5.9 silently ignores unknown or misplaced YAML keys.
  test "configuration uses only keys read by Litestream 0.5.9 at each level" do
    config = YAML.safe_load_file(Rails.root.join("deploy/litestream.yml"))

    assert_allowed_keys config, %w[access-key-id secret-access-key l0-retention l0-retention-check-interval levels snapshot dbs]
    config.fetch("levels").each do |level|
      assert_allowed_keys level, %w[interval]
    end
    assert_allowed_keys config.fetch("snapshot"), %w[interval retention]

    config.fetch("dbs").each do |database|
      assert_allowed_keys database, %w[path monitor-interval checkpoint-interval replica]
      assert_allowed_keys database.fetch("replica"), %w[type bucket path endpoint region sync-interval]
    end
  end

  private

  def assert_allowed_keys(mapping, allowed)
    assert_kind_of Hash, mapping
    assert_empty mapping.keys - allowed, "Unknown or misplaced Litestream keys"
  end
end
