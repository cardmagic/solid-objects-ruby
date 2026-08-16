# rbs_inline: enabled

require "solid_objects/process_registry"
require "solid_objects/activation_manager"
require "solid_objects/activation"
require "solid_objects/executor"
require "solid_objects/lease_renewer"
require "solid_objects/polling_backoff"

module SolidObjects
  class Worker
    # @rbs @process_registry: ProcessRegistry
    # @rbs @activation_manager: ActivationManager
    # @rbs @activations: Hash[Integer, Activation]
    # @rbs @stopped: bool
    # @rbs @shutdown_requested: bool
    # @rbs @polling_backoff: PollingBackoff

    # @rbs (?process_registry: ProcessRegistry) -> void
    def initialize(process_registry: ProcessRegistry.new)
      @process_registry = process_registry
      process_record = process_registry.register
      @activation_manager = ActivationManager.new(owner_id: process_record.id)
      @activations = {}
      @stopped = false
      @shutdown_requested = false
      @polling_backoff = PollingBackoff.new(
        minimum_interval: [
          SolidObjects.configuration.polling_interval,
          SolidObjects.configuration.lease_renewal_interval
        ].min,
        maximum_interval: [
          SolidObjects.configuration.idle_polling_interval,
          SolidObjects.configuration.lease_renewal_interval
        ].min,
        on_change: ->(transition) do
          SolidObjects.instrument(
            :"polling.interval_changed",
            role: "actors",
            **transition
          )
        end
      )
    end

    # @rbs () -> Integer
    def run_once
      return 0 if stopped?

      process_registry.heartbeat
      maintain_cached_activations
      activation = cached_ready_activation || activation_manager.claim_next
      return 0 unless activation

      activations[activation.lease.instance_id] = activation
      processed = LeaseRenewer.new(
        activation:,
        process_registry:
      ).around { activation.drain }
      release_activation(activation) if activation.pass_exhausted?
      processed
    rescue ActorDestroyed
      release_activation(activation) if activation
      0
    rescue StateMigrationError, ApplicationWriteForbidden, LostActivation => error
      release_activation(activation) if activation
      SolidObjects.configuration.logger.error(
        event: "solid_objects.worker.error",
        process_id: process_registry.process_record&.id,
        error_class: error.class.name,
        error_message: error.message
      )
      0
    end

    # @rbs (?max_passes: Integer) -> Integer
    def run_until_idle(max_passes: 1_000)
      total = 0

      max_passes.times do
        processed = run_once
        break if processed.zero?

        total += processed
      end

      total
    end

    # @rbs () -> void
    def run
      ProcessRegistry.warn_if_polling_is_only_cross_process_wake_up

      until shutdown_requested?
        wake_up = SolidObjects.wake_up
        watch = wake_up.respond_to?(:watch) ? wake_up.watch : wake_up
        processed = run_once
        if processed.positive?
          polling_backoff.reset(:work)
          next
        end

        notified = watch.wait(timeout: current_polling_interval)
        if notified == false
          polling_backoff.record_idle
        else
          polling_backoff.reset(:wake_up)
        end
      end
    ensure
      stop
    end

    # @rbs () -> void
    def request_shutdown
      @shutdown_requested = true
      SolidObjects.wake_up.signal
    end

    # @rbs () -> void
    def stop
      return if stopped?

      @stopped = true
      process_registry.start_draining
      activations.each_value(&:deactivate)
      activations.clear
      process_registry.stop
    end

    # @rbs () -> bool
    def stopped?
      @stopped
    end

    # @rbs () -> bool
    def shutdown_requested?
      @shutdown_requested
    end

    # @rbs () -> Float
    def current_polling_interval
      polling_backoff.current_interval
    end

    private

    attr_reader :process_registry, :activation_manager, :activations, :polling_backoff

    # @rbs () -> Activation?
    def cached_ready_activation
      activations.each_value.find(&:ready?)
    end

    # @rbs () -> void
    def maintain_cached_activations
      activations.each_value do |activation|
        if activation.idle?
          release_activation(activation)
        elsif activation.lease_renewal_due?
          activation.renew_lease
        end
      rescue LostActivation
        release_activation(activation)
      end
    end

    # @rbs (Activation) -> void
    def release_activation(activation)
      activations.delete(activation.lease.instance_id)
      activation.yield_ready_messages if activation.pass_exhausted?
      activation.deactivate
    end
  end
end
