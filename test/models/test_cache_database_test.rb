require "test_helper"

class TestCacheDatabaseTest < ActiveSupport::TestCase
  test "Rails prepares the cache schema in a separate worker-local database" do
    primary = ActiveRecord::Base.connection_pool
    cache = SolidCache::Entry.connection_pool
    assert_not_same primary, cache
    assert_not_equal primary.db_config.database, cache.db_config.database
    assert_equal ActiveRecord::Base.configurations.configs_for(env_name: "test", name: "cache").database,
      cache.db_config.database
    assert_kind_of Integer, SolidCache::Entry.count
  end
end
