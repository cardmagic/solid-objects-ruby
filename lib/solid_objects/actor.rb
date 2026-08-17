# rbs_inline: enabled

module SolidObjects
  class Actor
    EffectIntent = Data.define(:name, :arguments, :success_operation, :failure_operation)
    CommitActionIntent = Data.define(:name, :arguments)
    # The reminders table holds a name in 191 characters.
    REMINDER_NAME_LIMIT = 191
    REMINDER_KEY_SEPARATOR = ":"

    ReminderIntent = Data.define(:name, :operation, :at, :arguments, :interval_seconds, :missed_policy)
    OutboundMessageIntent = Data.define(:actor_type, :actor_id, :operation, :arguments, :available_at, :idempotency_key)

    class << self
      # @rbs (Class) -> void
      def inherited(subclass)
        super
        subclass.instance_variable_set(:@definition, definition.duplicate)
        subclass.instance_variable_set(:@generated_attribute_methods, generated_attribute_methods.dup)
      end

      # @rbs (?String | Symbol) -> String
      def actor_type(value = nil)
        if value
          @actor_type = value.to_s
          SolidObjects.register_actor(@actor_type, self)
        end

        @actor_type ||= default_actor_type
      end

      # @rbs (Symbol | String, ?default: untyped) -> StateDefinition::Attribute
      def attribute(name, default: nil)
        attribute_name = name.to_sym
        ensure_attribute_methods_available!(attribute_name)
        attribute = definition.add_attribute(attribute_name, default:)
        @defining_attribute_methods = true
        begin
          define_method(attribute_name) { state.fetch(attribute_name) }
          define_method(:"#{attribute_name}=") { |value| state.write(attribute_name, value) }
          generated_attribute_methods[attribute_name] = true
          generated_attribute_methods[:"#{attribute_name}="] = true
        ensure
          @defining_attribute_methods = false
        end
        attribute
      end

      # @rbs (Symbol | String) { (*untyped, **untyped) -> untyped } -> ActorDefinition::Handler
      def message(name, &block)
        definition.add_message(name, block)
      end

      # @rbs (Symbol | String) { (*untyped, **untyped) -> untyped } -> ActorDefinition::Handler
      def query(name, &block)
        definition.add_query(name, block)
      end

      # @rbs (Symbol | String, ?broadcast: Symbol) ?{ () -> untyped } -> ActorDefinition::Handler
      def observable(name, broadcast: :invalidation, &block)
        definition.add_observable(name, block, broadcast:)
      end

      # @rbs (Symbol | String) { (untyped, untyped) -> untyped } -> ActorDefinition::Handler
      def broadcast_payload(name, &block)
        raise InvalidActor, "payload broadcasts require a block" unless block

        definition.add_payload_broadcast(name, block)
      end

      # @rbs (?Integer) -> Integer
      def state_version(version = nil)
        definition.set_state_version(version) if version
        definition.state_version
      end

      # @rbs (from: Integer, to: Integer) { (Hash[String, untyped]) -> Hash[String, untyped] } -> ActorDefinition::StateMigration
      def migrate_state(from:, to:, &block)
        definition.add_state_migration(from:, to:, block:)
      end

      # @rbs () { () -> untyped } -> Proc
      def on_activate(&block)
        definition.activation_hooks << block
        block
      end

      # @rbs () { () -> untyped } -> Proc
      def on_deactivate(&block)
        definition.deactivation_hooks << block
        block
      end

      # @rbs (String | Integer) -> Reference
      def ref(actor_id)
        ensure_registered!
        Reference.new(actor_type:, actor_id: actor_id.to_s)
      end

      # @rbs () -> ActorDefinition
      def definition
        (@definition ||= ActorDefinition.new).synchronize_instance_messages(self)
      end

      # @rbs () -> Class
      def ensure_registered!
        SolidObjects.register_actor(actor_type, self)
      end

      private

      # @rbs (Symbol) -> void
      def method_added(name)
        super
        generated_attribute_methods.delete(name) unless @defining_attribute_methods
      end

      # @rbs () -> Hash[Symbol, bool]
      def generated_attribute_methods
        @generated_attribute_methods ||= {}
      end

      # @rbs (Symbol) -> void
      def ensure_attribute_methods_available!(attribute_name)
        conflicting_name = [ attribute_name, :"#{attribute_name}=" ].find do |method_name|
          method_defined?(method_name) ||
            private_method_defined?(method_name) ||
            protected_method_defined?(method_name)
        end
        return unless conflicting_name

        raise InvalidActor, "attribute #{attribute_name.inspect} conflicts with actor method #{conflicting_name}"
      end

      # @rbs () -> String
      def default_actor_type
        raise InvalidActor, "anonymous actor classes must declare actor_type" unless name

        name
      end
    end

    # @rbs @actor_id: String
    # @rbs @state: State
    # @rbs @effect_intents: Array[EffectIntent]
    # @rbs @commit_action_intents: Array[CommitActionIntent]
    # @rbs @reminder_intents: Array[ReminderIntent]
    # @rbs @outbound_message_intents: Array[OutboundMessageIntent]

    attr_reader :actor_id, :state

    # @rbs (actor_id: String, state: State) -> void
    def initialize(actor_id:, state:)
      @actor_id = actor_id
      @state = state
      @effect_intents = []
      @commit_action_intents = []
      @reminder_intents = []
      @outbound_message_intents = []
    end

    # @rbs () -> MessageContext?
    def current_message
      Context.current_message
    end

    # @rbs (Symbol | String, String, ?details: Hash[String | Symbol, untyped]) -> bot
    def reject(code, message, details: {})
      rejection_code = code.to_s
      unless rejection_code.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
        raise InvalidRejectionCode,
          "invalid rejection code #{rejection_code.inspect}; expected a letter or underscore followed by letters, digits, or underscores"
      end

      raise Rejected.new(code: rejection_code, message:, details:)
    end

    # @rbs (Symbol | String, ?on_success: Symbol | String?, ?on_failure: Symbol | String?, **untyped) -> nil
    def emit(name, on_success: nil, on_failure: nil, **arguments)
      validate_effect_callback!(on_success)
      validate_effect_callback!(on_failure)
      EffectIntent.new(
        name: name.to_s,
        arguments: Serialization.dump(arguments),
        success_operation: on_success&.to_s,
        failure_operation: on_failure&.to_s
      ).tap do |intent|
        effect_intents << intent
      end
      nil
    end

    # @rbs (Symbol | String, **untyped) -> nil
    def commit_action(name, **arguments)
      CommitActionIntent.new(
        name: name.to_s,
        arguments: Serialization.dump(arguments)
      ).tap do |intent|
        commit_action_intents << intent
      end
      nil
    end

    # A reminder is identified by its name, and without a key that name is the
    # operation, so one actor holds one alarm per operation. A key gives an actor
    # an alarm per item it is waiting on, which is what an actor holding a queue
    # of scheduled work needs; the key is the caller's own identifier for the
    # item, and scheduling the same key again moves that item's alarm.
    # @rbs (at: Time, ?every: Numeric?, ?missed: Symbol | String, ?key: (String | Symbol | Integer)?) -> OperationDispatcher
    def schedule(at:, every: nil, missed: :latest, key: nil)
      interval_seconds = every&.to_f
      if interval_seconds && !interval_seconds.positive?
        raise ArgumentError, "reminder interval must be positive"
      end
      missed_policy = missed.to_s
      unless %w[all latest].include?(missed_policy)
        raise ArgumentError, "missed reminder policy must be all or latest"
      end
      reminder_key = validated_reminder_key(key)

      OperationDispatcher.new(
        actor_type: self.class.actor_type,
        handlers: self.class.definition.messages
      ) do |operation, arguments|
        ReminderIntent.new(
          name: reminder_name(operation:, key: reminder_key),
          operation: operation.to_s,
          at:,
          arguments: Serialization.dump(arguments),
          interval_seconds:,
          missed_policy:
        ).tap do |intent|
          reminder_intents << intent
        end
        nil
      end
    end

    # @rbs ((String | Symbol | Integer)?) -> String?
    def validated_reminder_key(key)
      return nil if key.nil?

      reminder_key = key.to_s
      raise ArgumentError, "reminder key must not be empty" if reminder_key.empty?

      reminder_key
    end

    # A keyed name is the operation, a colon, and the key, so an operation
    # holding a colon of its own would make two different schedules produce one
    # name: an unkeyed "deliver:item" and a "deliver" keyed "item" would share a
    # row, and the second would silently take the first one's alarm. Refusing a
    # colon in the operation keeps unkeyed names free of colons, which leaves
    # the two kinds of name disjoint and lets a key hold colons of its own.
    #
    # The length is checked on the composed name rather than the key alone,
    # because a long operation and a short key can exceed the column just as
    # easily as the reverse. Both are refused here rather than at the insert,
    # once the turn is already doing work.
    # @rbs (operation: Symbol | String, key: String?) -> String
    def reminder_name(operation:, key:)
      operation_name = operation.to_s
      if operation_name.include?(REMINDER_KEY_SEPARATOR)
        raise ArgumentError,
          "reminder operation #{operation_name.inspect} must not contain #{REMINDER_KEY_SEPARATOR.inspect}"
      end
      return operation_name if key.nil?

      name = "#{operation_name}#{REMINDER_KEY_SEPARATOR}#{key}"
      if name.length > REMINDER_NAME_LIMIT
        raise ArgumentError,
          "reminder name #{name.length} characters exceeds the #{REMINDER_NAME_LIMIT} the database holds"
      end

      name
    end

    # @rbs (Reference, ?available_at: Time?, ?idempotency_key: String?) -> OperationDispatcher
    def send_to(reference, available_at: nil, idempotency_key: nil)
      actor_class = SolidObjects.registry.fetch(reference.actor_type)
      OperationDispatcher.new(
        actor_type: reference.actor_type,
        handlers: actor_class.definition.messages
      ) do |operation, arguments|
        stage_outbound_message(reference:, operation:, arguments:, available_at:, idempotency_key:)
        nil
      end
    end

    # @rbs (Symbol | String, Hash[String, untyped]) -> untyped
    def invoke(operation, arguments)
      handler = self.class.definition.messages[operation.to_sym] ||
        self.class.definition.queries[operation.to_sym]
      raise UnknownMessage, "unknown operation #{operation.inspect} for #{self.class.actor_type}" unless handler

      guard_application_writes(operation.to_s) do
        instance_exec(**keyword_arguments(arguments), &handler.block)
      end
    end

    # @rbs () -> Hash[String, untyped]
    def observable_values
      guard_application_writes("observables") do
        self.class.definition.observables.each_with_object({}) do |(name, handler), values|
          values[name.to_s] = Serialization.dump(instance_exec(&handler.block))
        end
      end
    end

    # @rbs (Symbol | String) -> untyped
    def observable_value(name)
      observable_name = name.to_sym
      handler = self.class.definition.observables[observable_name]
      raise UnknownMessage, "unknown observable #{name.inspect}" unless handler

      guard_application_writes("observable.#{observable_name}") do
        Serialization.dump(instance_exec(&handler.block))
      end
    end

    # @rbs () -> void
    def activate
      guard_application_writes("on_activate") do
        self.class.definition.activation_hooks.each { |hook| instance_exec(&hook) }
      end
    end

    # @rbs () -> void
    def deactivate
      guard_application_writes("on_deactivate") do
        self.class.definition.deactivation_hooks.each { |hook| instance_exec(&hook) }
      end
    end

    # @rbs (reference: Reference, operation: Symbol | String, arguments: Hash[Symbol | String, untyped], ?available_at: Time?, idempotency_key: String?) -> OutboundMessageIntent
    def stage_outbound_message(reference:, operation:, arguments:, available_at: nil, idempotency_key: nil)
      OutboundMessageIntent.new(
        actor_type: reference.actor_type,
        actor_id: reference.actor_id,
        operation: operation.to_s,
        arguments: Serialization.dump(arguments),
        available_at:,
        idempotency_key:
      ).tap { |intent| outbound_message_intents << intent }
    end

    # @rbs () -> Array[EffectIntent]
    def drain_effect_intents
      effect_intents.shift(effect_intents.length)
    end

    # @rbs () -> Array[CommitActionIntent]
    def drain_commit_action_intents
      commit_action_intents.shift(commit_action_intents.length)
    end

    # @rbs () -> Array[ReminderIntent]
    def drain_reminder_intents
      reminder_intents.shift(reminder_intents.length)
    end

    # @rbs () -> Array[OutboundMessageIntent]
    def drain_outbound_message_intents
      outbound_message_intents.shift(outbound_message_intents.length)
    end

    # @rbs () -> void
    def discard_intents
      effect_intents.clear
      commit_action_intents.clear
      reminder_intents.clear
      outbound_message_intents.clear
    end

    private

    attr_reader :effect_intents,
      :commit_action_intents,
      :reminder_intents,
      :outbound_message_intents

    # @rbs (String) { () -> untyped } -> untyped
    def guard_application_writes(operation, &block)
      ApplicationWriteGuard.call(
        actor_type: self.class.actor_type,
        actor_id:,
        operation:,
        &block
      )
    end

    # @rbs (Hash[String, untyped]) -> Hash[Symbol, untyped]
    def keyword_arguments(arguments)
      arguments.each_with_object({}) { |(key, value), converted| converted[key.to_sym] = value }
    end

    # @rbs (Symbol | String?) -> void
    def validate_effect_callback!(operation)
      return unless operation
      return if self.class.definition.messages.key?(operation.to_sym)

      raise UnknownMessage, "unknown effect callback operation #{operation.inspect}"
    end
  end
end
