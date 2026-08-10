# frozen_string_literal: true

require "database_test_helper"
require "timeout"

class RedisWakeUpTest < ActiveSupport::TestCase
  REDIS_URL = ENV.fetch("SOLID_OBJECTS_REDIS_URL", "redis://127.0.0.1:6379/15")

  setup do
    skip unless redis_available?

    @adapter = SolidObjects::WakeUpAdapters::Redis.new(url: REDIS_URL)
  end

  teardown { @adapter&.stop }

  test "a signal from another client wakes a waiter" do
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

    signal_from_another_client

    elapsed = Timeout.timeout(5) { woken.pop }
    waiter.join(5)
    assert_operator elapsed, :<, 1.0,
      "a published signal should wake the waiter well before the timeout"
  end

  test "waiting returns after the timeout when nothing signals" do
    @adapter.listen
    started = monotonic_now

    @adapter.wait(timeout: 0.3)

    elapsed = monotonic_now - started
    assert_operator elapsed, :>=, 0.2
    assert_operator elapsed, :<, 3.0
  end

  # The supervisor shares one adapter across runtime roles, so concurrent
  # waiters go through a single instance.
  test "every waiter on one shared adapter wakes on one signal" do
    waiters = 3
    waiting = Queue.new
    woken = Queue.new
    threads = Array.new(waiters) do
      Thread.new do
        @adapter.listen
        waiting << true
        started = monotonic_now
        @adapter.wait(timeout: 5)
        woken << monotonic_now - started
      end
    end
    waiters.times { Timeout.timeout(5) { waiting.pop } }

    signal_from_another_client

    elapsed = waiters.times.map { Timeout.timeout(10) { woken.pop } }
    threads.each { |thread| thread.join(6) }
    assert_operator elapsed.max, :<, 1.0,
      "every waiter should wake on the signal, not time out"
  end

  test "one subscription serves every waiter in the process" do
    threads = Array.new(3) { Thread.new { @adapter.listen } }
    threads.each { |thread| thread.join(5) }

    subscribers = @adapter.instance_variable_get(:@subscriber)
    assert subscribers.alive?, "one background subscription should serve the process"
  end

  test "signalling never raises into the caller" do
    broken = SolidObjects::WakeUpAdapters::Redis.new(url: "redis://127.0.0.1:1/0")

    assert_nothing_raised { broken.signal }
    assert_equal false, broken.signal
  ensure
    broken&.stop
  end

  test "waiting never raises into the caller" do
    broken = SolidObjects::WakeUpAdapters::Redis.new(url: "redis://127.0.0.1:1/0")
    started = monotonic_now

    assert_nothing_raised { broken.wait(timeout: 0.1) }

    assert_operator monotonic_now - started, :>=, 0.05,
      "a failed wait must still pace itself rather than spin"
  ensure
    broken&.stop
  end

  test "stopping releases the subscription" do
    @adapter.listen

    assert @adapter.stop
    refute @adapter.instance_variable_get(:@subscriber)
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

  test "a missing redis gem is reported clearly" do
    error = assert_raises(ArgumentError) do
      SolidObjects::WakeUpAdapters::Redis.new(url: REDIS_URL, client: :not_a_client)
    end

    assert_match(/respond to/, error.message)
  end

  private

  def redis_available?
    require "redis"
    ::Redis.new(url: REDIS_URL, timeout: 1).ping == "PONG"
  rescue LoadError, StandardError
    false
  end

  def monotonic_now
    ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
  end

  # Models a commit in a different process: a publish on its own client.
  def signal_from_another_client
    other = SolidObjects::WakeUpAdapters::Redis.new(url: REDIS_URL)
    Thread.new { other.signal }.join(5)
  ensure
    other&.stop
  end
end
