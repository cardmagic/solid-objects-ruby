# rbs_inline: enabled

module SolidObjects
  class Configuration
    # @rbs @table_name_prefix: String
    # @rbs @polling_interval: Float
    # @rbs @sync_polling_interval: Float
    # @rbs @lease_duration: Float
    # @rbs @lease_renewal_interval: Float
    # @rbs @idle_deactivation_timeout: Float
    # @rbs @max_messages_per_activation_pass: Integer
    # @rbs @max_activation_duration: Float
    # @rbs @max_mailbox_length: Integer
    # @rbs @claim_scan_limit: Integer
    # @rbs @max_payload_bytes: Integer
    # @rbs @max_state_bytes: Integer
    # @rbs @max_result_bytes: Integer
    # @rbs @max_attempts: Integer
    # @rbs @retry_delay: Proc
    # @rbs @process_heartbeat_interval: Float
    # @rbs @process_alive_threshold: Float
    # @rbs @shutdown_timeout: Float
    # @rbs @message_retention: Numeric
    # @rbs @message_retention_by_actor_type: Hash[String, Numeric]
    # @rbs @instance_retention_by_actor_type: Hash[String, Numeric]
    # @rbs @process_retention: Numeric
    # @rbs @prune_batch_size: Integer
    # @rbs @worker_count: Integer
    # @rbs @effect_worker_count: Integer
    # @rbs @broadcast_worker_count: Integer
    # @rbs @reminder_scheduler_count: Integer
    # @rbs @connects_to: Hash[Symbol, untyped]?
    # @rbs @logger: untyped
    # @rbs @stream_signing_secret: String?
    # @rbs @broadcast_adapter: Proc?
    # @rbs @wake_up_adapter: untyped
    # @rbs @authorize_message: Proc
    # @rbs @authorize_query: Proc
    # @rbs @authorize_destroy: Proc
    # @rbs @authorize_subscription: Proc
    # @rbs @authorize_administration: Proc

    attr_accessor :table_name_prefix,
      :polling_interval,
      :sync_polling_interval,
      :lease_duration,
      :lease_renewal_interval,
      :idle_deactivation_timeout,
      :max_messages_per_activation_pass,
      :max_activation_duration,
      :max_mailbox_length,
      :claim_scan_limit,
      :max_payload_bytes,
      :max_state_bytes,
      :max_result_bytes,
      :max_attempts,
      :retry_delay,
      :process_heartbeat_interval,
      :process_alive_threshold,
      :shutdown_timeout,
      :message_retention,
      :message_retention_by_actor_type,
      :instance_retention_by_actor_type,
      :process_retention,
      :prune_batch_size,
      :worker_count,
      :effect_worker_count,
      :broadcast_worker_count,
      :reminder_scheduler_count,
      :connects_to,
      :logger,
      :stream_signing_secret,
      :broadcast_adapter,
      :wake_up_adapter,
      :authorize_message,
      :authorize_query,
      :authorize_destroy,
      :authorize_subscription,
      :authorize_administration

    # @rbs () -> void
    def initialize
      @table_name_prefix = "solid_objects_"
      @polling_interval = 0.1
      @sync_polling_interval = 0.05
      @lease_duration = 30.0
      @lease_renewal_interval = 10.0
      @idle_deactivation_timeout = 30.0
      @max_messages_per_activation_pass = 50
      @max_activation_duration = 5.0
      @max_mailbox_length = 10_000
      @claim_scan_limit = 100
      @max_payload_bytes = 1.megabyte
      @max_state_bytes = 5.megabytes
      @max_result_bytes = 1.megabyte
      @max_attempts = 5
      @retry_delay = ->(attempt) { [ 2**(attempt - 1), 60 ].min.to_f }
      @process_heartbeat_interval = 15.0
      @process_alive_threshold = 60.0
      @shutdown_timeout = 15.0
      @message_retention = 30.days
      @message_retention_by_actor_type = {}
      @instance_retention_by_actor_type = {}
      @process_retention = 7.days
      @prune_batch_size = 1_000
      @worker_count = 1
      @effect_worker_count = 1
      @broadcast_worker_count = 1
      @reminder_scheduler_count = 1
      @connects_to = nil
      @stream_signing_secret = nil
      @broadcast_adapter = nil
      @wake_up_adapter = nil
      @logger = if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
        Rails.logger
      else
        Logger.new($stdout)
      end
      @authorize_message = ->(**) { false }
      @authorize_query = ->(**) { false }
      @authorize_destroy = ->(**) { false }
      @authorize_subscription = ->(**) { false }
      @authorize_administration = ->(**) { false }
    end

    # @rbs () -> self
    def validate!
      unless table_name_prefix.match?(/\A[a-z][a-z0-9_]*\z/)
        raise ArgumentError, "table_name_prefix must contain lowercase letters, digits, and underscores"
      end

      unless lease_duration > lease_renewal_interval
        raise ArgumentError, "lease_duration must be greater than lease_renewal_interval"
      end

      component_counts.each do |name, value|
        raise ArgumentError, "#{name} must not be negative" if value.negative?
      end
      if component_counts.values.sum.zero?
        raise ArgumentError, "at least one runtime component must be configured"
      end

      positive_values.each do |name, value|
        raise ArgumentError, "#{name} must be positive" unless value.positive?
      end
      message_retention_by_actor_type.each do |actor_type, retention|
        raise ArgumentError, "actor type cannot be empty" if actor_type.to_s.empty?
        raise ArgumentError, "message retention must be positive" unless retention.positive?
      end
      instance_retention_by_actor_type.each do |actor_type, retention|
        raise ArgumentError, "actor type cannot be empty" if actor_type.to_s.empty?
        raise ArgumentError, "instance retention must be positive" unless retention.positive?
      end

      self
    end

    private

    # @rbs () -> Hash[Symbol, Numeric]
    def positive_values
      {
        polling_interval:,
        sync_polling_interval:,
        lease_duration:,
        lease_renewal_interval:,
        max_messages_per_activation_pass:,
        max_activation_duration:,
        max_mailbox_length:,
        claim_scan_limit:,
        max_payload_bytes:,
        max_state_bytes:,
        max_result_bytes:,
        max_attempts:,
        process_heartbeat_interval:,
        process_alive_threshold:,
        shutdown_timeout:,
        message_retention:,
        process_retention:,
        prune_batch_size:
      }
    end

    # @rbs () -> Hash[Symbol, Integer]
    def component_counts
      {
        worker_count:,
        effect_worker_count:,
        broadcast_worker_count:,
        reminder_scheduler_count:
      }
    end
  end
end
