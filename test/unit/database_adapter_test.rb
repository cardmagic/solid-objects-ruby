# frozen_string_literal: true

require "database_test_helper"

class DatabaseAdapterTest < ActiveSupport::TestCase
  Connection = Data.define(:adapter_name)

  test "selects the coordination adapter for the active database" do
    adapter = SolidObjects::DatabaseAdapter.for(ActiveRecord::Base.connection)
    expected_class = {
      postgresql: SolidObjects::DatabaseAdapters::Postgresql,
      mysql: SolidObjects::DatabaseAdapters::Mysql,
      sqlite: SolidObjects::DatabaseAdapters::Sqlite
    }.fetch(database_family)

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

  # Trilogy speaks the MySQL protocol but reports "Trilogy", so a pattern that
  # only knows the gem name rejects a database that is fully supported.
  test "selects the MySQL coordination adapter for Trilogy" do
    adapter = SolidObjects::DatabaseAdapter.for(Connection.new(adapter_name: "Trilogy"))

    assert_instance_of SolidObjects::DatabaseAdapters::Mysql, adapter
    assert adapter.supports_skip_locked?
    assert_equal "FOR UPDATE SKIP LOCKED", adapter.claim_lock
  end

  test "names the family behind every MySQL client" do
    %w[Mysql2 Trilogy].each do |name|
      assert_equal :mysql,
        SolidObjects::DatabaseAdapter.family(Connection.new(adapter_name: name)),
        "#{name} speaks the MySQL protocol"
    end
  end

  test "names the family for PostgreSQL and SQLite" do
    assert_equal :postgresql,
      SolidObjects::DatabaseAdapter.family(Connection.new(adapter_name: "PostgreSQL"))
    assert_equal :sqlite,
      SolidObjects::DatabaseAdapter.family(Connection.new(adapter_name: "SQLite"))
  end

  test "names no family for an unsupported adapter" do
    assert_nil SolidObjects::DatabaseAdapter.family(Connection.new(adapter_name: "Oracle"))
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
