# frozen_string_literal: true

require "database_test_helper"
require "solid_objects/doctor"

class DatabaseVersionTest < ActiveSupport::TestCase
  test "reports the server version for the connected adapter" do
    version = SolidObjects.database_adapter.server_version

    assert_kind_of Gem::Version, version
    assert_operator version, :>, Gem::Version.new("0")
    # A packed integer such as 170010 would compare greater than any minimum,
    # making the check pass on servers it should flag.
    assert_operator version, :<, Gem::Version.new("1000"),
      "the version must be a human version, not a packed integer"
  end

  test "an old PostgreSQL server is still detected" do
    skip unless database_family == :postgresql
    adapter = SolidObjects.database_adapter
    adapter.define_singleton_method(:with_connection) { |&block| block.call(Struct.new(:database_version).new(90_600)) }

    assert_operator adapter.server_version, :<, adapter.minimum_server_version
  ensure
    restore(adapter, :with_connection)
  end

  test "the observed version is read once for status and message" do
    adapter = SolidObjects.database_adapter
    reads = 0
    real = adapter.method(:server_version)
    adapter.define_singleton_method(:server_version) {
      reads += 1
      real.call
    }

    SolidObjects::Doctor.new.call.check(:database_server)

    assert_equal 1, reads, "the doctor should observe the server version once"
  ensure
    restore(adapter, :server_version)
  end

  test "a supported server passes verification" do
    assert_empty SolidObjects.database_adapter.unsupported_server_reasons
  end

  test "an old server is reported rather than raised" do
    adapter = SolidObjects.database_adapter
    adapter.define_singleton_method(:server_version) { Gem::Version.new("1.0") }

    reasons = adapter.unsupported_server_reasons

    assert_equal 1, reasons.length
    assert_match(/requires/, reasons.first)
  ensure
    restore(adapter, :server_version)
  end

  test "an unreadable server version does not raise" do
    adapter = SolidObjects.database_adapter
    adapter.define_singleton_method(:server_version) { raise "boom" }

    assert_nothing_raised { adapter.unsupported_server_reasons }
  ensure
    restore(adapter, :server_version)
  end

  test "the doctor reports a supported server" do
    report = SolidObjects::Doctor.new.call

    check = report.check(:database_server)
    assert_equal :pass, check.status
    assert_match(/\d+\./, check.message)
  end

  test "the doctor warns about an unsupported server" do
    adapter = SolidObjects.database_adapter
    adapter.define_singleton_method(:unsupported_server_reasons) { |_observed = nil| [ "too old" ] }

    check = SolidObjects::Doctor.new.call.check(:database_server)

    assert_equal :warn, check.status
    assert_match(/too old/, check.message)
  ensure
    restore(adapter, :unsupported_server_reasons)
  end

  test "an unsupported server does not fail the report" do
    adapter = SolidObjects.database_adapter
    adapter.define_singleton_method(:unsupported_server_reasons) { |_observed = nil| [ "too old" ] }

    assert SolidObjects::Doctor.new.call.healthy?
  ensure
    restore(adapter, :unsupported_server_reasons)
  end

  test "MySQL verifies that Solid Objects tables use InnoDB" do
    skip unless database_family == :mysql

    assert_empty SolidObjects.database_adapter.unsupported_server_reasons
  end

  test "MySQL reports a non-transactional storage engine" do
    skip unless database_family == :mysql
    adapter = SolidObjects.database_adapter
    adapter.define_singleton_method(:non_innodb_tables) { [ "solid_objects_messages" ] }

    reasons = adapter.unsupported_server_reasons

    assert(reasons.any? { |reason| reason.include?("InnoDB") })
  ensure
    restore(adapter, :non_innodb_tables)
  end

  private

  # Skipped tests still run their ensure, where the local is nil.
  def restore(adapter, name)
    return unless adapter&.singleton_class&.method_defined?(name)

    adapter.singleton_class.send(:remove_method, name)
  end
end
