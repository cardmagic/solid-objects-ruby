# rbs_inline: enabled

module SolidObjects
  module WakeUpAdapters
    POSTGRESQL_FLOOR_MS = 2.9
    REDIS_FLOOR_MS = 5.7
    REDIS_URL_VARIABLE = "SOLID_OBJECTS_REDIS_URL"
    PROBE_TIMEOUT_SECONDS = 2.0

    @pooled_warning_mutex = Thread::Mutex.new
    @pooled_warning_emitted = false

    module_function

    NAMES = %i[automatic in_process postgresql redis].freeze

    # @rbs (?untyped) -> untyped
    def for(connection = Record.connection)
      select(connection)
    end

    # @rbs (untyped) -> untyped
    def build(setting)
      return select if setting.nil? || setting == :automatic
      return named(setting) if setting.is_a?(Symbol)

      configured(setting)
    end

    # @rbs (Symbol) -> untyped
    def named(name)
      case name
      when :in_process then labelled(WakeUp.new, :in_process, false, nil, "in-process signalling was requested")
      when :postgresql then labelled(Postgresql.new, :postgresql_notify, true, POSTGRESQL_FLOOR_MS, "PostgreSQL LISTEN was requested")
      when :redis then labelled(Redis.new(url: redis_url), :redis, true, REDIS_FLOOR_MS, "Redis was requested")
      else
        raise ArgumentError, "unknown wake_up_adapter #{name.inspect}, expected one of #{NAMES.join(", ")} or an adapter"
      end
    end

    # @rbs (untyped) -> untyped
    def configured(adapter)
      return adapter unless adapter.respond_to?(:capability=)
      return adapter if adapter.respond_to?(:default_capability)

      labelled(adapter, :configured, true, nil, "an adapter was configured, so selection did not run")
    end

    # @rbs (untyped, Symbol, bool, Numeric?, String) -> untyped
    def labelled(adapter, name, crosses_processes, floor, reason)
      adapter.capability = WakeUpCapability.new(
        adapter: name,
        crosses_processes:,
        measured_floor_ms: floor,
        reason:
      )
      adapter
    end

    # @rbs (?untyped) -> untyped
    def select(connection = Record.connection)
      url = redis_url
      return redis_selection(url) if url

      family = DatabaseAdapter.family(connection)
      return postgresql_selection if family == :postgresql

      polling_selection(family)
    end

    # @rbs (untyped) -> bool
    def notifications_deliver?(adapter)
      return false unless adapter.listen
      return false unless notify_probe_channel(adapter.channel)

      adapter.wait(timeout: PROBE_TIMEOUT_SECONDS)
    rescue
      false
    ensure
      adapter.stop
    end

    # @rbs (String) -> bool
    def notify_probe_channel(channel)
      connection = Record.connection_pool.send(:new_connection)
      connection.execute("NOTIFY #{connection.quote_table_name(channel)}")
      true
    ensure
      disconnect_probe(connection)
    end

    # @rbs (untyped) -> void
    def disconnect_probe(connection)
      connection&.disconnect!
    rescue
      nil
    end

    # @rbs () -> void
    def reset_pooled_warning!
      @pooled_warning_mutex.synchronize { @pooled_warning_emitted = false }
    end

    # @rbs () -> String?
    def redis_url
      value = ENV[REDIS_URL_VARIABLE].to_s
      value.empty? ? nil : value
    end

    # @rbs (String) -> untyped
    def redis_selection(url)
      labelled(
        Redis.new(url:), :redis, true, REDIS_FLOOR_MS,
        "#{REDIS_URL_VARIABLE} is set, so Redis carries the signal between processes"
      )
    end

    # @rbs () -> untyped
    def postgresql_selection
      adapter = Postgresql.new
      return pooled_selection unless notifications_deliver?(adapter)

      labelled(
        adapter, :postgresql_notify, true, POSTGRESQL_FLOOR_MS,
        "a probe notification arrived, so PostgreSQL LISTEN carries the signal between processes"
      )
    end

    # @rbs () -> untyped
    def pooled_selection
      warn_pooled_session_once
      polling_adapter(
        "a probe notification did not arrive, so LISTEN cannot carry the signal " \
        "between processes; a transaction pooler such as PgBouncer is the usual cause"
      )
    end

    # @rbs (Symbol?) -> untyped
    def polling_selection(family)
      polling_adapter(
        "#{family || "this database"} has no notification channel and " \
        "#{REDIS_URL_VARIABLE} is not set"
      )
    end

    # @rbs (String) -> untyped
    def polling_adapter(reason)
      labelled(
        WakeUp.new, :polling, false,
        SolidObjects.configuration.idle_polling_interval * 1_000, reason
      )
    end

    # @rbs () -> void
    def warn_pooled_session_once
      @pooled_warning_mutex.synchronize do
        return if @pooled_warning_emitted

        SolidObjects.configuration.logger.warn(
          event: "solid_objects.wake_up.pooled_session",
          reason: "PostgreSQL notifications were not selected because a probe " \
            "notification did not arrive"
        )
        @pooled_warning_emitted = true
      end
    end
  end
end
