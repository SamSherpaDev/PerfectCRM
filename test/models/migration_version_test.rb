require "test_helper"

class MigrationVersionTest < ActiveSupport::TestCase
  test "every migration filename carries a 14-digit version prefix" do
    bad = Dir[Rails.root.join("db/migrate/*.rb")].map { |path| File.basename(path) }
      .reject { |file| file.match?(/\A\d{14}_.*\.rb\z/) }
    assert_empty bad, "Migrations must use 14-digit timestamps, got: #{bad.join(", ")}"
  end
end
