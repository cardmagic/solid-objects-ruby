# rbs_inline: enabled

require "solid_objects/mailbox"
require "solid_objects/synchronous_invocation"

module SolidObjects
  class Doctor
    class Check
      # @rbs @name: Symbol
      # @rbs @status: Symbol
      # @rbs @message: String

      attr_reader :name, :status, :message

      # @rbs (name: Symbol, status: Symbol, message: String) -> void
      def initialize(name:, status:, message:)
        @name = name
        @status = status
        @message = message
        freeze
      end

      # @rbs () -> bool
      def failed?
        status == :fail
      end
    end

    class Report
      # @rbs @checks: Array[Check]

      attr_reader :checks

      # @rbs (checks: Array[Check]) -> void
      def initialize(checks:)
        @checks = checks.freeze
        freeze
      end

      # @rbs () -> bool
      def healthy?
        checks.none?(&:failed?)
      end

      # @rbs (Symbol) -> Check
      def check(name)
        checks.find { |candidate| candidate.name == name } ||
          raise(KeyError, "unknown doctor check #{name.inspect}")
      end

      # @rbs () -> String
      def to_s
        lines = [ "Solid Objects doctor #{SolidObjects::VERSION}" ]
        lines.concat(
          checks.map do |check|
            "#{check.status.to_s.upcase.ljust(4)} #{check.name}: #{check.message}"
          end
        )
        lines.join("\n")
      end
    end

    EXPECTED_COLUMNS = {
      processes: %w[id kind hostname pid last_heartbeat_at shutdown_state],
      instances: %w[
        id actor_type actor_id state state_version next_message_sequence
        activation_owner_id activation_token activation_expires_at
        activation_generation
      ],
      messages: %w[
        id instance_id message_kind arguments sequence attempt_count request_id
        result error rejection completed_at rejected_at
      ],
      ready_messages: %w[id message_id instance_id sequence available_at],
      claimed_messages: %w[
        id message_id instance_id process_id activation_token
        activation_generation claimed_at
      ],
      reminders: %w[id instance_id message_name next_run_at status],
      effects: %w[id message_id instance_id effect_id status available_at],
      broadcasts: %w[id message_id instance_id broadcast_id status available_at],
      dead_letters: %w[id message_id instance_id actor_type actor_id attempts]
    }.freeze

    class ProbeActor < Actor
      actor_type "solid_objects_doctor"

      # @rbs (value: String) -> String
      def ping(value:)
        value
      end
    end

    # @rbs @connection: untyped
    # @rbs @configuration: Configuration

    # @rbs (?connection: untyped, ?configuration: Configuration) -> void
    def initialize(
      connection: SolidObjects::Record.connection,
      configuration: SolidObjects.configuration
    )
      @connection = connection
      @configuration = configuration
    end

    # @rbs () -> Report
    def call
      configuration_check = check_configuration
      schema_check = check_schema
      checks = [
        configuration_check,
        schema_check,
        check_authorization,
        schema_check.failed? ? skipped_runtime : check_runtime,
        ready_for_round_trip?(configuration_check, schema_check) ?
          check_sync_round_trip :
          skipped_round_trip
      ]
      Report.new(checks:)
    end

    private

    attr_reader :connection, :configuration

    # @rbs () -> Check
    def check_configuration
      configuration.validate!
      pass(:configuration, "configuration is valid")
    rescue => error
      fail_check(:configuration, "#{error.class}: #{error.message}")
    end

    # @rbs () -> Check
    def check_schema
      missing_tables = expected_table_names - connection.data_sources
      unless missing_tables.empty?
        return fail_check(:schema, "missing tables: #{missing_tables.join(", ")}")
      end

      missing_columns = EXPECTED_COLUMNS.each_with_object([]) do |(name, expected), missing|
        table_name = SolidObjects.table_name(name)
        actual = connection.columns(table_name).map(&:name)
        (expected - actual).each { |column| missing << "#{table_name}.#{column}" }
      end
      unless missing_columns.empty?
        return fail_check(:schema, "missing columns: #{missing_columns.join(", ")}")
      end

      pass(:schema, "schema matches the #{SolidObjects::VERSION} runtime")
    rescue => error
      fail_check(:schema, "#{error.class}: #{error.message}")
    end

    # @rbs () -> Check
    def check_authorization
      outcomes = policy_probes.to_h do |name, arguments|
        outcome = configuration.public_send(name).call(**arguments) ? :allow : :deny
        [ name, outcome ]
      rescue
        [ name, :unknown ]
      end
      allowed = outcomes.select { |_, outcome| outcome == :allow }.keys
      unknown = outcomes.select { |_, outcome| outcome == :unknown }.keys

      if allowed.empty? && unknown.empty?
        return warn_check(
          :authorization,
          "all five policies denied a neutral context; review the generated initializer before use"
        )
      end
      risky = allowed & %i[
        authorize_destroy
        authorize_subscription
        authorize_administration
      ]
      unless risky.empty?
        return warn_check(
          :authorization,
          "sensitive policies allowed a neutral context: #{risky.join(", ")}"
        )
      end
      unless unknown.empty?
        return warn_check(
          :authorization,
          "#{allowed.length} of 5 policies allowed a neutral context; " \
            "#{unknown.join(", ")} could not evaluate without application context"
        )
      end

      pass(:authorization, "#{allowed.length} of 5 policies allowed a neutral context")
    end

    # @rbs () -> Check
    def check_runtime
      cutoff = SolidObjects.database_adapter.database_now -
        configuration.process_alive_threshold
      counts = Process
        .where(shutdown_state: "running", last_heartbeat_at: cutoff..)
        .group(:kind)
        .count
      if counts.empty?
        return info(
          :runtime,
          "no live runtime roles; workerless synchronous calls are available, asynchronous features are not"
        )
      end

      summary = counts.sort.map { |kind, count| "#{kind}=#{count}" }.join(", ")
      pass(:runtime, "live runtime roles: #{summary}")
    rescue => error
      fail_check(:runtime, "#{error.class}: #{error.message}")
    end

    # @rbs () -> Check
    def check_sync_round_trip
      actor_id = SecureRandom.uuid
      value = SecureRandom.hex(8)
      process_registry = SolidObjects.caller_process.process_registry
      reference = ProbeActor.ref(actor_id)
      message_reference = Mailbox.new.enqueue(
        reference,
        :ping,
        { value: },
        kind: "sync"
      )
      result = SynchronousInvocation.new.call(message_reference, timeout: 5.seconds)
      raise Error, "unexpected round-trip result" unless result == value

      pass(:sync_round_trip, "durable synchronous actor call completed without a worker")
    rescue => error
      fail_check(:sync_round_trip, "#{error.class}: #{error.message}")
    ensure
      Instance.where(actor_type: ProbeActor.actor_type, actor_id:).delete_all if actor_id
      process_registry&.stop
      process_registry&.process_record&.delete
    end

    # @rbs (Check, Check) -> bool
    def ready_for_round_trip?(configuration_check, schema_check)
      !configuration_check.failed? && !schema_check.failed?
    end

    # @rbs () -> Check
    def skipped_runtime
      skip(:runtime, "schema check failed")
    end

    # @rbs () -> Check
    def skipped_round_trip
      skip(:sync_round_trip, "configuration or schema check failed")
    end

    # @rbs () -> Hash[Symbol, Hash[Symbol, untyped]]
    def policy_probes
      actor_arguments = {
        actor_type: ProbeActor.actor_type,
        actor_id: "doctor",
        authorization_context: nil
      }
      {
        authorize_message: actor_arguments.merge(
          message_name: "ping",
          arguments: { "value" => "doctor" }
        ),
        authorize_query: actor_arguments.merge(
          message_name: "value",
          arguments: {}
        ),
        authorize_destroy: actor_arguments,
        authorize_subscription: actor_arguments,
        authorize_administration: {
          action: "doctor",
          resource: "runtime",
          resource_id: nil,
          authorization_context: nil
        }
      }
    end

    # @rbs () -> Array[String]
    def expected_table_names
      EXPECTED_COLUMNS.keys.map { |name| SolidObjects.table_name(name) }
    end

    # @rbs (Symbol, String) -> Check
    def pass(name, message)
      Check.new(name:, status: :pass, message:)
    end

    # @rbs (Symbol, String) -> Check
    def info(name, message)
      Check.new(name:, status: :info, message:)
    end

    # @rbs (Symbol, String) -> Check
    def warn_check(name, message)
      Check.new(name:, status: :warn, message:)
    end

    # @rbs (Symbol, String) -> Check
    def fail_check(name, message)
      Check.new(name:, status: :fail, message:)
    end

    # @rbs (Symbol, String) -> Check
    def skip(name, message)
      Check.new(name:, status: :skip, message:)
    end
  end
end
