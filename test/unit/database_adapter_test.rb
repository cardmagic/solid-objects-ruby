# frozen_string_literal: true

require "database_test_helper"

class DatabaseAdapterTest < ActiveSupport::TestCase
  Connection = Data.define(:adapter_name)

  test "selects the coordination adapter for the active database" do
    adapter = SolidObjects::DatabaseAdapter.for(ActiveRecord::Base.connection)
    expected_class = case ActiveRecord::Base.connection.adapter_name
    when /postgres/i
      SolidObjects::DatabaseAdapters::Postgresql
    when /mysql/i
      SolidObjects::DatabaseAdapters::Mysql
    else
      SolidObjects::DatabaseAdapters::Sqlite
    end

    assert_instance_of expected_class, adapter
  end

  test "selects the PostgreSQL coordination adapter" do
    adapter = SolidObjects::DatabaseAdapter.for(Connection.new(adapter_name: "PostgreSQL"))

    assert_instance_of SolidObjects::DatabaseAdapters::Postgresql, adapter
    assert adapter.supports_skip_locked?
    assert_equal "FOR UPDATE SKIP LOCKED", adapter.claim_lock
  end

  test "selects the MySQL coordination adapter" do
    adapter = SolidObjects::DatabaseAdapter.for(Connection.new(adapter_name: "Mysql2"))

    assert_instance_of SolidObjects::DatabaseAdapters::Mysql, adapter
    assert adapter.supports_skip_locked?
    assert_equal "FOR UPDATE SKIP LOCKED", adapter.claim_lock
  end

  test "rejects unsupported databases" do
    assert_raises(SolidObjects::UnsupportedDatabase) do
      SolidObjects::DatabaseAdapter.for(Connection.new(adapter_name: "Oracle"))
    end
  end

  test "reads current time from the active database" do
    adapter = SolidObjects::DatabaseAdapter.for(ActiveRecord::Base.connection)

    assert_in_delta Time.now.utc.to_f, adapter.database_now.to_f, 2
  end
end
