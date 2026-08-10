# frozen_string_literal: true

require "test_helper"

class WakeUpAdaptersTest < ActiveSupport::TestCase
  Connection = Struct.new(:adapter_name)

  test "selects PostgreSQL notifications for a PostgreSQL connection" do
    adapter = SolidObjects::WakeUpAdapters.for(Connection.new("PostgreSQL"))

    assert_instance_of SolidObjects::WakeUpAdapters::Postgresql, adapter
  end

  test "falls back to the in-process wake-up for MySQL" do
    adapter = SolidObjects::WakeUpAdapters.for(Connection.new("Mysql2"))

    assert_instance_of SolidObjects::WakeUp, adapter
  end

  test "falls back to the in-process wake-up for SQLite" do
    adapter = SolidObjects::WakeUpAdapters.for(Connection.new("SQLite"))

    assert_instance_of SolidObjects::WakeUp, adapter
  end

  test "the fallback satisfies the wake-up contract" do
    adapter = SolidObjects::WakeUpAdapters.for(Connection.new("SQLite"))

    assert_respond_to adapter, :signal
    assert_respond_to adapter, :wait
  end
end
