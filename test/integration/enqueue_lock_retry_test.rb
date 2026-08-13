# frozen_string_literal: true

require "database_test_helper"
require "timeout"

class EnqueueLockRetryTest < ActiveSupport::TestCase
  class CartActor < SolidObjects::Actor
    actor_type "enqueue-retry-cart"

    attribute :items, default: -> { [] }

    def add(product_id:)
      self.items += [ product_id ]
    end
  end

  setup { CartActor.ensure_registered! }

  # SQLite's own busy handler hides the gap until it is exhausted, so these
  # tests disable it. Only a Ruby-level retry can complete the enqueue.
  test "an enqueue retries a contended write instead of failing immediately" do
    skip unless sqlite?
    reference = CartActor.ref("alice")
    lock = hold_write_lock_briefly

    message = SolidObjects::Record.connection_pool.with_connection do |connection|
      suspend_sqlite_busy_wait(connection) do
        reference.async.add(product_id: "shirt")
      end
    end

    assert_equal 1, message.sequence
  ensure
    release_lock(lock)
  end

  test "concurrent enqueues all succeed while a lock is contended" do
    skip unless sqlite?
    reference = CartActor.ref("alice")
    start = Queue.new
    errors = Queue.new
    sequences = Queue.new
    lock = hold_write_lock_briefly

    # The adapter is shared, so the busy wait is suspended once for every
    # thread rather than stubbed per thread.
    SolidObjects::Record.connection_pool.with_connection do |connection|
      suspend_sqlite_busy_wait(connection) do
        threads = 6.times.map do
          Thread.new do
            SolidObjects::Record.connection_pool.with_connection do |thread_connection|
              thread_connection.raw_connection.busy_handler_timeout = 0
              start.pop
              sequences << reference.async.add(product_id: "shirt").sequence
            rescue => error
              errors << error
            end
          end
        end
        threads.length.times { start << true }
        threads.each { |thread| thread.join(30) }
      end
    end

    assert_empty errors.size.times.map { errors.pop }
    assert_equal (1..6).to_a, sequences.size.times.map { sequences.pop }.sort
  ensure
    release_lock(lock)
  end

  test "a permanently locked database still raises rather than hanging" do
    skip unless sqlite?
    SolidObjects.configuration.lock_retry_attempts = 2
    reference = CartActor.ref("alice")
    lock = hold_write_lock

    error = assert_raises(ActiveRecord::StatementTimeout) do
      Timeout.timeout(20) do
        SolidObjects::Record.connection_pool.with_connection do |connection|
          suspend_sqlite_busy_wait(connection) do
            reference.async.add(product_id: "shirt")
          end
        end
      end
    end

    assert_match(/database is locked/, error.message)
  ensure
    release_lock(lock)
  end

  private

  def sqlite?
    database_family == :sqlite
  end

  # Holds the write lock long enough that an enqueue must wait, then releases
  # so a correctly retrying enqueue completes.
  def hold_write_lock_briefly
    hold_write_lock(release_after: 0.25)
  end

  def hold_write_lock(release_after: nil)
    locked = Queue.new
    release = Queue.new
    thread = Thread.new do
      SolidObjects::Record.connection_pool.with_connection do
        SolidObjects::Record.transaction do
          SolidObjects::Process.create!(
            id: SecureRandom.uuid,
            kind: "lock-holder",
            hostname: "test-host",
            pid: ::Process.pid,
            started_at: Time.current,
            last_heartbeat_at: Time.current,
            metadata: {}
          )
          locked << true
          if release_after
            mutex = Thread::Mutex.new
            mutex.synchronize do
              Thread::ConditionVariable.new.wait(mutex, release_after)
            end
          else
            release.pop
          end
        end
      end
    end
    Timeout.timeout(5) { locked.pop }
    [ thread, release, release_after ]
  end

  def release_lock(lock)
    return unless lock

    thread, release, release_after = lock
    release << true unless release_after
    thread.join(10)
  end
end
