# frozen_string_literal: true

require "database_test_helper"
require "solid_objects/doctor"

class WakeUpSelectionTest < ActiveSupport::TestCase
  class CustomAdapter
    attr_accessor :capability

    def signal = true

    def watch = self

    def wait(timeout:) = false
  end

  setup do
    SolidObjects.reset_wake_up!
    @redis_url = ENV.delete("SOLID_OBJECTS_REDIS_URL")
    @configured_adapter = SolidObjects.configuration.wake_up_adapter
  end

  teardown do
    ENV.delete("SOLID_OBJECTS_REDIS_URL")
    ENV["SOLID_OBJECTS_REDIS_URL"] = @redis_url if @redis_url
    SolidObjects.configuration.wake_up_adapter = @configured_adapter
    SolidObjects.reset_wake_up!
  end

  test "an explicitly configured adapter wins" do
    explicit = SolidObjects::WakeUp.new
    SolidObjects.configuration.wake_up_adapter = explicit

    assert_same explicit, SolidObjects.wake_up
  end

  test "a configured adapter keeps the capability it reports about itself" do
    SolidObjects.configuration.wake_up_adapter = SolidObjects::WakeUp.new

    capability = SolidObjects.wake_up.capability
    assert_equal :in_process, capability.adapter
    assert_not capability.crosses_processes
    assert_match(/another process/i, capability.reason)
  end

  test "the doctor warns about a configured in-process adapter" do
    SolidObjects.configuration.authorize_administration = ->(**) { true }
    SolidObjects.configuration.wake_up_adapter = SolidObjects::WakeUp.new

    check = SolidObjects::Doctor.new.call.check(:wake_up)
    assert_equal :warn, check.status
    assert_match(/cannot wake another/i, check.message)
  end

  test "a configured adapter that reports no capability is recorded as configured" do
    SolidObjects.configuration.wake_up_adapter = CustomAdapter.new

    capability = SolidObjects.wake_up.capability
    assert_equal :configured, capability.adapter
    assert capability.crosses_processes
  end

  test "threads that race for the adapter select it once" do
    selections = Queue.new
    start = Queue.new
    resolved = Queue.new

    with_module_method(:build, ->(_setting) {
      selections << true
      sleep 0.05
      SolidObjects::WakeUp.new
    }) do
      threads = 8.times.map do
        Thread.new do
          start.pop
          resolved << SolidObjects.wake_up
        end
      end
      threads.length.times { start << true }
      threads.each(&:join)
    end

    assert_equal 1, selections.size
    assert_equal 1, resolved.size.times.map { resolved.pop.object_id }.uniq.size
  end

  test "in_process opts out of selection" do
    SolidObjects.configuration.wake_up_adapter = :in_process

    capability = SolidObjects.wake_up.capability
    assert_equal :in_process, capability.adapter
    assert_not capability.crosses_processes
  end

  test "a name selects that adapter without probing" do
    ENV["SOLID_OBJECTS_REDIS_URL"] = "redis://127.0.0.1:6379/15"
    SolidObjects.configuration.wake_up_adapter = :redis

    capability = SolidObjects.wake_up.capability
    assert_equal :redis, capability.adapter
    assert_match(/requested/i, capability.reason)
  end

  test "a requested postgresql adapter polls when the database has no channel" do
    skip if database_family == :postgresql
    warnings = []
    SolidObjects.configuration.logger = Logger.new(IO::NULL).tap do |logger|
      logger.define_singleton_method(:warn) { |payload| warnings << payload }
    end
    SolidObjects.configuration.wake_up_adapter = :postgresql

    capability = SolidObjects.wake_up.capability
    assert_equal :polling, capability.adapter
    assert_not capability.crosses_processes
    assert_match(/notification channel/i, capability.reason)
    assert_equal [ "solid_objects.wake_up.unavailable" ],
      warnings.map { |payload| payload[:event].to_s }
  end

  test "a requested redis adapter polls when no url is set" do
    warnings = []
    SolidObjects.configuration.logger = Logger.new(IO::NULL).tap do |logger|
      logger.define_singleton_method(:warn) { |payload| warnings << payload }
    end
    SolidObjects.configuration.wake_up_adapter = :redis

    capability = SolidObjects.wake_up.capability
    assert_equal :polling, capability.adapter
    assert_match(/SOLID_OBJECTS_REDIS_URL/, capability.reason)
    assert_equal [ "solid_objects.wake_up.unavailable" ],
      warnings.map { |payload| payload[:event].to_s }
  end

  test "an adapter without watch is still accepted" do
    legacy = Class.new do
      def signal = true

      def wait(timeout:) = false
    end.new
    SolidObjects.configuration.wake_up_adapter = legacy

    assert_same SolidObjects.configuration, SolidObjects.configuration.validate!
    assert_same legacy, SolidObjects.wake_up
  end

  test "an adapter that cannot signal is refused" do
    SolidObjects.configuration.wake_up_adapter = Object.new

    error = assert_raises(ArgumentError) { SolidObjects.configuration.validate! }
    assert_match(/signal/, error.message)
  end

  test "an unknown name is refused when the configuration is validated" do
    SolidObjects.configuration.wake_up_adapter = :carrier_pigeon

    error = assert_raises(ArgumentError) { SolidObjects.configuration.validate! }
    assert_match(/carrier_pigeon/, error.message)
    assert_match(/automatic/, error.message)
  end

  test "an unknown name is refused rather than silently polling" do
    SolidObjects.configuration.wake_up_adapter = :carrier_pigeon

    error = assert_raises(ArgumentError) { SolidObjects.wake_up }
    assert_match(/carrier_pigeon/, error.message)
    assert_match(/automatic/, error.message)
  end

  test "a redis url selects redis on any database" do
    ENV["SOLID_OBJECTS_REDIS_URL"] = "redis://127.0.0.1:6379/15"

    capability = SolidObjects.wake_up.capability
    assert_equal :redis, capability.adapter
    assert capability.crosses_processes
    assert_match(/redis/i, capability.reason)
  end

  test "postgresql selects notifications when a probe notification arrives" do
    skip unless database_family == :postgresql

    capability = SolidObjects.wake_up.capability
    assert_equal :postgresql_notify, capability.adapter
    assert capability.crosses_processes
    assert_operator capability.measured_floor_ms, :<, 100
    assert_match(/probe notification arrived/i, capability.reason)
  end

  test "postgresql polls when a probe notification does not arrive" do
    skip unless database_family == :postgresql

    with_undelivered_notifications do
      capability = SolidObjects.wake_up.capability

      assert_equal :polling, capability.adapter
      assert_not capability.crosses_processes
      assert_match(/pooler/i, capability.reason)
    end
  end

  test "a listener wakes from a notification sent on another connection" do
    skip unless database_family == :postgresql
    channel = "solid_objects_probe_parity"
    adapter = SolidObjects::WakeUpAdapters::Postgresql.new(channel:)

    assert adapter.listen
    SolidObjects::Record.connection_pool.with_connection do |connection|
      connection.execute("NOTIFY #{connection.quote_table_name(channel)}")
    end

    assert adapter.wait(timeout: 2.0)
  ensure
    adapter&.stop
  end

  test "a database without a channel polls and reports its floor" do
    skip if database_family == :postgresql

    capability = SolidObjects.wake_up.capability
    assert_equal :polling, capability.adapter
    assert_not capability.crosses_processes
    assert_equal SolidObjects.configuration.idle_polling_interval * 1_000,
      capability.measured_floor_ms
    assert_match(/no notification channel/i, capability.reason)
  end

  test "a pooled postgresql session falls back to polling and warns once" do
    skip unless database_family == :postgresql
    warnings = []
    SolidObjects.configuration.logger = Logger.new(IO::NULL).tap do |logger|
      logger.define_singleton_method(:warn) { |payload| warnings << payload }
    end
    with_pooled_session do
      capability = SolidObjects.wake_up.capability

      assert_equal :polling, capability.adapter
      assert_match(/pool/i, capability.reason)
    end

    assert_equal 1, warnings.count { |payload| payload[:event].to_s.include?("wake_up") }
  end

  test "the capability names the adapter that is actually installed" do
    expected = {
      "SolidObjects::WakeUpAdapters::Postgresql" => :postgresql_notify,
      "SolidObjects::WakeUpAdapters::Redis" => :redis,
      "SolidObjects::WakeUp" => :polling
    }

    assert_equal expected.fetch(SolidObjects.wake_up.class.name),
      SolidObjects.wake_up.capability.adapter
  end

  test "selection survives a database that cannot be reached" do
    with_unreachable_database do
      capability = SolidObjects.wake_up.capability

      assert_equal :in_process, capability.adapter
      assert_not capability.crosses_processes
      assert_match(/could not be reached/i, capability.reason)
    end
  end

  test "a load error is not reported as an unreachable database" do
    SolidObjects::WakeUpAdapters.singleton_class.alias_method(:built, :build)
    SolidObjects::WakeUpAdapters.define_singleton_method(:build) do |_name|
      raise NameError, "uninitialized constant SolidObjects::Record"
    end

    assert_raises(NameError) { SolidObjects.wake_up }
  ensure
    SolidObjects::WakeUpAdapters.singleton_class.alias_method(:build, :built)
  end

  test "the doctor reports the selected adapter" do
    SolidObjects.configuration.authorize_administration = ->(**) { true }
    check = SolidObjects::Doctor.new.call.check(:wake_up)

    assert check, "the doctor should report a wake_up check"
    assert_equal SolidObjects.wake_up.capability.crosses_processes, check.status == :pass
    assert_match(/#{SolidObjects.wake_up.capability.adapter}/, check.message)
  end

  private

  def with_module_method(name, replacement)
    adapters = SolidObjects::WakeUpAdapters
    original = adapters.method(name)
    adapters.define_singleton_method(name, replacement)
    yield
  ensure
    adapters.define_singleton_method(name, original)
  end

  def with_pooled_session(&block)
    with_undelivered_notifications(&block)
  end

  def with_undelivered_notifications
    adapter_class = SolidObjects::WakeUpAdapters::Postgresql
    original = adapter_class.instance_method(:wait)
    adapter_class.define_method(:wait) { |timeout:| false }
    yield
  ensure
    adapter_class.define_method(:wait, original)
  end

  def with_unreachable_database(&block)
    with_module_method(:select, ->(*) { raise ActiveRecord::ConnectionNotEstablished }, &block)
  end
end
