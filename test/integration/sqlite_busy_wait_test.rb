# rbs_inline: enabled

require "database_test_helper"
require "timeout"

class SqliteBusyWaitTest < ActiveSupport::TestCase
  test "background transactions let the SQLite lock holder commit while waiting" do
    skip "SQLite busy handlers" unless database_family == :sqlite

    SolidObjectsTestDomainRecord.columns
    ready = Queue.new
    start = Queue.new
    waiting = Queue.new
    errors = Queue.new
    SolidObjects.configuration.lock_retry_attempts = 0
    adapter = SolidObjects.database_adapter
    contender = Thread.new do
      SolidObjects::Record.connection_pool.with_connection do |connection|
        raw_connection = connection.raw_connection
        raw_connection.busy_timeout = 100
        raw_connection.define_singleton_method(:busy_handler) do |&handler|
          super() do |count|
            waiting << true if count.zero?
            handler.call(count)
          end
        end
        ready << true
        start.pop
        adapter.transaction { SolidObjectsTestDomainRecord.create!(name: "contender") }
      rescue => error
        errors << error
      ensure
        waiting << true
        if raw_connection && !raw_connection.closed?
          raw_connection.singleton_class.remove_method(:busy_handler)
          raw_connection.busy_handler_timeout = configured_sqlite_busy_handler_timeout
        end
      end
    end
    Timeout.timeout(5) { ready.pop }
    SolidObjects::Record.transaction do
      SolidObjectsTestDomainRecord.create!(name: "holder")
      start << true
      Timeout.timeout(5) { waiting.pop }
    end
    assert contender.join(5), "the contender did not finish after the holder committed"
    assert_empty errors.size.times.map { errors.pop }
    assert_equal %w[contender holder], SolidObjectsTestDomainRecord.order(:name).pluck(:name)
  ensure
    start << true if start
    contender&.kill&.join if contender&.alive?
  end
end
