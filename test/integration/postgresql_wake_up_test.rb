# frozen_string_literal: true

require "database_test_helper"
require "timeout"

class PostgresqlWakeUpTest < ActiveSupport::TestCase
  setup do
    skip unless postgresql?

    @adapter = SolidObjects::WakeUpAdapters::Postgresql.new
  end

  teardown { @adapter&.stop }

  test "a signal from another connection wakes a waiter" do
    waiting = Queue.new
    woken = Queue.new
    waiter = Thread.new do
      @adapter.listen
      waiting << true
      started = monotonic_now
      @adapter.wait(timeout: 5)
      woken << monotonic_now - started
    end
    Timeout.timeout(5) { waiting.pop }

    signal_from_another_connection

    elapsed = Timeout.timeout(5) { woken.pop }
    waiter.join(5)
    assert_operator elapsed, :<, 1.0,
      "a cross-connection signal should wake the waiter well before the timeout"
  end

  test "waiting returns after the timeout when nothing signals" do
    @adapter.listen
    started = monotonic_now

    @adapter.wait(timeout: 0.2)

    elapsed = monotonic_now - started
    assert_operator elapsed, :>=, 0.15
    assert_operator elapsed, :<, 2.0
  end

  test "every waiter wakes on one signal" do
    waiters = 3
    waiting = Queue.new
    woken = Queue.new
    adapters = Array.new(waiters) { SolidObjects::WakeUpAdapters::Postgresql.new }
    threads = adapters.map do |adapter|
      Thread.new do
        adapter.listen
        waiting << true
        adapter.wait(timeout: 5)
        woken << true
      end
    end
    waiters.times { Timeout.timeout(5) { waiting.pop } }

    signal_from_another_connection

    waiters.times { Timeout.timeout(5) { woken.pop } }
    threads.each { |thread| thread.join(5) }
    assert_equal 0, woken.size
  ensure
    adapters&.each(&:stop)
  end

  test "signalling never raises into the caller" do
    broken = SolidObjects::WakeUpAdapters::Postgresql.new(channel: "solid_objects_missing")
    broken.define_singleton_method(:notify_channel) { raise "boom" }

    assert_nothing_raised { broken.signal }
  ensure
    broken&.stop
  end

  test "waiting never raises into the caller" do
    broken = SolidObjects::WakeUpAdapters::Postgresql.new
    broken.define_singleton_method(:listening_connection) { raise "boom" }
    started = monotonic_now

    assert_nothing_raised { broken.wait(timeout: 0.1) }

    assert_operator monotonic_now - started, :>=, 0.05,
      "a failed wait must still pace itself rather than spin"
  ensure
    broken&.stop
  end

  test "the adapter satisfies the wake-up contract" do
    assert_respond_to @adapter, :signal
    assert_respond_to @adapter, :wait
    SolidObjects.configuration.wake_up_adapter = @adapter

    assert_same @adapter, SolidObjects.wake_up
  ensure
    SolidObjects.configuration.wake_up_adapter = nil
    SolidObjects.instance_variable_set(:@wake_up, nil)
  end

  private

  def postgresql?
    SolidObjects::Record.connection.adapter_name.match?(/postgres/i)
  end

  def monotonic_now
    ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
  end

  # Models a commit in a different process: a plain NOTIFY on its own connection.
  def signal_from_another_connection
    Thread.new { SolidObjects::WakeUpAdapters::Postgresql.new.signal }.join(5)
  end
end
