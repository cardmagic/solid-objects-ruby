# frozen_string_literal: true

require "database_test_helper"

# A synchronous deadline is enforced by asking the database to interrupt the
# statement, so recognising that interruption is what turns it back into a
# SyncEnqueueTimeout for the caller. Each client reports it differently, and a
# client whose report is not recognised surfaces a raw database error instead.
class DeadlineErrorTest < ActiveSupport::TestCase
  MAX_EXECUTION_TIME_EXCEEDED = 3024

  # mysql2 exposes `error_number`; Trilogy exposes `error_code`.
  Mysql2Error = Class.new(StandardError) do
    def error_number = MAX_EXECUTION_TIME_EXCEEDED
  end

  TrilogyError = Class.new(StandardError) do
    def error_code = MAX_EXECUTION_TIME_EXCEEDED
  end

  setup do
    @adapter = SolidObjects::DatabaseAdapters::Mysql.new(SolidObjects::Record.connection)
  end

  test "recognises the interruption reported by mysql2" do
    with_deadline do
      assert @adapter.send(:deadline_error?, wrapped(Mysql2Error.new("interrupted")))
    end
  end

  test "recognises the interruption reported by Trilogy" do
    with_deadline do
      assert @adapter.send(:deadline_error?, wrapped(TrilogyError.new("interrupted"))),
        "a client that names the code error_code must still be recognised"
    end
  end

  test "recognises a statement timeout whatever the client called it" do
    with_deadline do
      assert @adapter.send(:deadline_error?, ActiveRecord::StatementTimeout.new("timeout"))
    end
  end

  test "recognises a lock wait timeout" do
    with_deadline do
      assert @adapter.send(:deadline_error?, ActiveRecord::LockWaitTimeout.new("waited"))
    end
  end

  test "leaves an unrelated database error alone" do
    unrelated = Class.new(StandardError) do
      def error_code = 1146
    end

    with_deadline do
      refute @adapter.send(:deadline_error?, wrapped(unrelated.new("no such table")))
    end
  end

  test "claims nothing outside a synchronous deadline" do
    refute @adapter.send(:deadline_error?, ActiveRecord::StatementTimeout.new("timeout"))
  end

  private

  # Active Record wraps the client error, so the code is only reachable through
  # the cause chain.
  def wrapped(client_error)
    raise_wrapped(client_error)
  rescue ActiveRecord::StatementInvalid => wrapper
    wrapper
  end

  def raise_wrapped(client_error)
    raise client_error
  rescue
    raise ActiveRecord::StatementInvalid, "wrapped"
  end

  def with_deadline(&block)
    SolidObjects::SyncDeadline.with(timeout: 5, &block)
  end
end
