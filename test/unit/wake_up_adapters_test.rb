# frozen_string_literal: true

require "test_helper"

class WakeUpAdaptersTest < ActiveSupport::TestCase
  Connection = Struct.new(:adapter_name)

  test "selects PostgreSQL notifications when a probe notification arrives" do
    with_delivered_notifications do
      adapter = SolidObjects::WakeUpAdapters.for(Connection.new("PostgreSQL"))

      assert_instance_of SolidObjects::WakeUpAdapters::Postgresql, adapter
    end
  end

  test "polls when a PostgreSQL probe notification does not arrive" do
    with_undelivered_notifications do
      adapter = SolidObjects::WakeUpAdapters.for(Connection.new("PostgreSQL"))

      assert_instance_of SolidObjects::WakeUp, adapter
      assert_equal :polling, adapter.capability.adapter
    end
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

  test "the in-process wake-up distinguishes a timeout from a signal" do
    adapter = SolidObjects::WakeUp.new

    assert_equal false, adapter.wait(timeout: 0.001)
  end

  test "the in-process wake-up does not miss a signal sent before waiting" do
    adapter = SolidObjects::WakeUp.new
    watch = adapter.watch

    adapter.signal

    assert_equal true, watch.wait(timeout: 1.0)
  end

  private

  def with_delivered_notifications(&block)
    with_probe(->(_adapter) { true }, &block)
  end

  def with_undelivered_notifications(&block)
    with_probe(->(_adapter) { false }, &block)
  end

  def with_probe(replacement)
    adapters = SolidObjects::WakeUpAdapters
    original = adapters.method(:notifications_deliver?)
    adapters.define_singleton_method(:notifications_deliver?, replacement)
    yield
  ensure
    adapters.define_singleton_method(:notifications_deliver?, original)
  end
end
