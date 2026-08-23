# rbs_inline: enabled

require "active_record"
require "active_support"
require "active_support/core_ext/numeric/bytes"
require "active_support/core_ext/numeric/time"
require "active_support/isolated_execution_state"
require "active_support/notifications"
require "json"
require "logger"
require "securerandom"

require "solid_objects/version"
require "solid_objects/errors"
require "solid_objects/sync_deadline"
require "solid_objects/callable_keywords"
require "solid_objects/configuration"
require "solid_objects/instrumentation"
require "solid_objects/log_subscriber"
require "solid_objects/serialization"
require "solid_objects/context"
require "solid_objects/actor_registry"
require "solid_objects/state"
require "solid_objects/operation_dispatcher"
require "solid_objects/actor_definition"
require "solid_objects/application_write_guard"
require "solid_objects/actor"
require "solid_objects/reference"
require "solid_objects/message_reference"
require "solid_objects/dead_letter_manager"
require "solid_objects/message_pruner"
require "solid_objects/instance_pruner"
require "solid_objects/process_pruner"
require "solid_objects/administration"
require "solid_objects/stream_name"
require "solid_objects/dom_identity"
require "solid_objects/stream_token"
require "solid_objects/component_token"
require "solid_objects/component_path_resolver"
require "solid_objects/turbo_stream_renderer"
require "solid_objects/actor_snapshot"
require "solid_objects/component_registration"
require "solid_objects/component_subscriptions"
require "solid_objects/component_view"
require "solid_objects/component_renderer"
require "solid_objects/payload_broadcast"
require "solid_objects/state_snapshot"
require "solid_objects/actor_view"
require "solid_objects/actor_channel"
require "solid_objects/action_cable_broadcast_adapter"
require "solid_objects/database_adapter"
require "solid_objects/wake_up"
require "solid_objects/wake_up_adapters/postgresql"
require "solid_objects/wake_up_adapters/redis"
require "solid_objects/wake_up_adapters"
require "solid_objects/polling_backoff"
require "solid_objects/effect_registry"
require "solid_objects/commit_action_registry"
require "solid_objects/lease"
require "solid_objects/lease_renewer"
# The reminder scheduler and the effect executor enqueue through the mailbox,
# and both run in the standalone worker where nothing else has loaded it. It
# was reachable only through the caller path, so requiring the gem was not
# enough to run a role that uses it.
require "solid_objects/mailbox"
require "solid_objects/transmission"
require "solid_objects/worker"
require "solid_objects/effect_executor"
require "solid_objects/reminder_scheduler"
require "solid_objects/broadcast_executor"
require "solid_objects/supervisor"
require "solid_objects/engine" if defined?(Rails::Engine)

module SolidObjects
  extend Instrumentation

  class << self
    # @rbs () -> Configuration
    def configuration
      @configuration ||= Configuration.new
    end

    # @rbs () { (Configuration) -> void } -> Configuration
    def configure
      yield configuration
      configuration.validate!
    end

    # @rbs () -> ActorRegistry
    def registry
      @registry ||= ActorRegistry.new
    end

    # @rbs () -> EffectRegistry
    def effect_registry
      @effect_registry ||= EffectRegistry.new
    end

    # @rbs (String | Symbol) { (Hash[String, untyped], EffectContext) -> untyped } -> Proc
    def register_effect(name, &handler)
      effect_registry.register(name, handler)
    end

    # @rbs (?effect_name: String | Symbol) { (Hash[String, untyped]) -> untyped } -> Proc
    def register_transmit(effect_name: Transmission::EFFECT_NAME, &deliver)
      raise ArgumentError, "register_transmit requires a delivery block" unless deliver

      register_effect(effect_name) do |arguments, context|
        Transmission.deliver_through(
          effect_name: effect_name.to_s,
          arguments:,
          context:,
          deliver:
        )
      end
    end

    # @rbs () -> CommitActionRegistry
    def commit_action_registry
      @commit_action_registry ||= CommitActionRegistry.new
    end

    # @rbs (String | Symbol) { (Hash[String, untyped], CommitActionContext) -> untyped } -> Proc
    def register_commit_action(name, &handler)
      commit_action_registry.register(name, handler)
    end

    # @rbs () -> Client
    def client
      require "solid_objects/client"
      @client ||= Client.new
    end

    # @rbs () -> CallerProcess
    def caller_process
      require "solid_objects/caller_process"
      @caller_process ||= CallerProcess.new
    end

    # @rbs () -> bool
    def reset_caller_process!
      caller_process = @caller_process
      @caller_process = nil
      return false unless caller_process

      caller_process.stop
    rescue ActiveRecord::ActiveRecordError
      false
    end

    # @rbs () -> DeadLetterManager
    def dead_letters
      @dead_letters ||= DeadLetterManager.new
    end

    # @rbs () -> Administration
    def administration
      @administration ||= Administration.new
    end

    # @rbs (String | Symbol) -> String
    def table_name(name)
      "#{configuration.table_name_prefix}#{name}"
    end

    # @rbs (String, Class) -> Class
    def register_actor(type, actor_class)
      registry.register(type, actor_class)
    end

    # @rbs (untyped) -> untyped
    def mutable_copy(value)
      Serialization.deep_copy(value)
    end

    # @rbs () -> void
    def reset!
      ProcessRegistry.reset_polling_warning! if defined?(ProcessRegistry)
      @configuration = Configuration.new
      @registry = ActorRegistry.new
      @client = nil
      @database_adapter = nil
      @wake_up = nil
      @caller_process = nil
      @effect_registry = EffectRegistry.new
      @commit_action_registry = CommitActionRegistry.new
      @dead_letters = nil
      @administration = nil
    end

    # @rbs () -> DatabaseAdapter
    def database_adapter
      require "solid_objects/database_adapter"
      @database_adapter ||= DatabaseAdapter.for(SolidObjects::Record.connection)
    end

    # @rbs () -> WakeUp
    def wake_up
      @wake_up ||= configuration.wake_up_adapter || WakeUp.new
    end
  end
end
