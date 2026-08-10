# rbs_inline: enabled

require "time"

module SolidObjects
  class DatabaseAdapter
    TRANSACTION_CLOCK = :solid_objects_transaction_clock
    TRANSACTION_CLOCK_SCOPE = :solid_objects_transaction_clock_scope

    class << self
      # @rbs (untyped) -> DatabaseAdapter
      def for(connection)
        case connection.adapter_name
        when /postgres/i
          DatabaseAdapters::Postgresql.new(connection)
        when /mysql/i
          DatabaseAdapters::Mysql.new(connection)
        when /sqlite/i
          DatabaseAdapters::Sqlite.new(connection)
        else
          raise UnsupportedDatabase, "unsupported database adapter #{connection.adapter_name.inspect}"
        end
      end
    end

    # @rbs @connection_pool: untyped
    # @rbs @fixed_connection: untyped

    # @rbs (untyped) -> void
    def initialize(connection)
      @connection_pool = connection.respond_to?(:pool) ? connection.pool : nil
      @fixed_connection = connection_pool ? nil : connection
    end

    # The oldest server the adapter has been exercised against. Reported rather
    # than enforced: refusing to boot on an untested server would be a worse
    # failure than running on one.
    # @rbs () -> Gem::Version?
    def minimum_server_version
      nil
    end

    # @rbs () -> Gem::Version
    def server_version
      with_connection do |connection|
        Gem::Version.new(connection.database_version.to_s)
      end
    end

    # One observed version decides both the status and the message. Reading it
    # again could let a transient failure replace an already determined result.
    # @rbs (?Gem::Version?) -> Array[String]
    def unsupported_server_reasons(observed = nil)
      observed ||= server_version
      reasons = []
      minimum = minimum_server_version
      if minimum && observed < minimum
        reasons << "#{self.class.name.demodulize} #{observed} is older than " \
          "Solid Objects requires, which is #{minimum}"
      end
      reasons.concat(additional_server_reasons)
      reasons
    rescue => error
      [ "the database server could not be verified: #{error.class}: #{error.message}" ]
    end

    # @rbs () -> Array[String]
    def additional_server_reasons
      []
    end

    # @rbs () -> bool
    def supports_skip_locked?
      false
    end

    # @rbs () -> String?
    def claim_lock
      nil
    end

    # @rbs () -> String
    def current_time_expression
      "CURRENT_TIMESTAMP"
    end

    # @rbs () -> Time
    def database_now
      return read_database_now unless ActiveSupport::IsolatedExecutionState[TRANSACTION_CLOCK_SCOPE]

      ActiveSupport::IsolatedExecutionState[TRANSACTION_CLOCK] ||= read_database_now
    end

    # @rbs () { () -> untyped } -> untyped
    def with_lock_retry
      yield
    end

    # @rbs () { () -> untyped } -> untyped
    def with_lock_probe
      yield
    end

    # @rbs () { () -> untyped } -> untyped
    def transaction(&block)
      raise DatabaseDeadlineExceeded, "synchronous invocation deadline expired" if SyncDeadline.expired?

      with_connection do |connection|
        with_transaction_deadline(connection) do
          connection.transaction(requires_new: true) do
            configure_transaction_deadline(connection)
            with_transaction_clock { block.call }
          end
        end
      end
    rescue => error
      raise unless deadline_error?(error)

      raise DatabaseDeadlineExceeded,
        "database lock wait exceeded the synchronous invocation deadline",
        cause: error
    end

    # @rbs (ActiveRecord::Relation[untyped]) -> ActiveRecord::Relation[untyped]
    def lock_candidates(relation)
      claim_lock ? relation.lock(claim_lock) : relation
    end

    private

    attr_reader :connection_pool, :fixed_connection

    # @rbs () { () -> untyped } -> untyped
    def with_transaction_clock
      return yield if ActiveSupport::IsolatedExecutionState[TRANSACTION_CLOCK_SCOPE]

      ActiveSupport::IsolatedExecutionState[TRANSACTION_CLOCK_SCOPE] = true
      begin
        yield
      ensure
        ActiveSupport::IsolatedExecutionState[TRANSACTION_CLOCK_SCOPE] = false
        ActiveSupport::IsolatedExecutionState[TRANSACTION_CLOCK] = nil
      end
    end

    # @rbs () -> Time
    def read_database_now
      value = with_connection do |connection|
        connection.select_value("SELECT #{current_time_expression}")
      end
      value.is_a?(Time) ? value.utc : Time.parse("#{value} UTC").utc
    end

    # @rbs (untyped) { () -> untyped } -> untyped
    def with_transaction_deadline(_connection)
      yield
    end

    # @rbs (untyped) -> void
    def configure_transaction_deadline(_connection)
    end

    # @rbs (Exception) -> bool
    def deadline_error?(_error)
      false
    end

    # @rbs () { (untyped) -> untyped } -> untyped
    def with_connection
      return yield fixed_connection unless connection_pool

      connection_pool.with_connection { |connection| yield connection }
    end
  end
end

require "solid_objects/database_adapters/postgresql"
require "solid_objects/database_adapters/mysql"
require "solid_objects/database_adapters/sqlite"
