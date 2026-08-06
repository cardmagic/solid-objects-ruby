# rbs_inline: enabled

module SolidObjects
  class Actor
    EffectIntent = Data.define(:name, :arguments, :success_message_name, :failure_message_name)
    ReminderIntent = Data.define(:name, :at, :arguments, :interval_seconds, :missed_policy)
    OutboundMessageIntent = Data.define(:actor_type, :actor_id, :message_name, :arguments, :available_at, :idempotency_key)

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

      # @rbs (Symbol | String) ?{ () -> untyped } -> ActorDefinition::Handler
      def observable(name, &block)
        definition.add_observable(name, block)
      end

      # @rbs (?Integer) -> Integer
      def state_version(version = nil)
        definition.set_state_version(version) if version
        definition.state_version
      end

      # @rbs (from: Integer, to: Integer) { (Hash[String, untyped]) -> Hash[String, untyped] } -> ActorDefinition::StateMigration
      def migrate_state(from:, to:, &block)
        definition.add_state_migration(from, to, block)
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
    # @rbs @reminder_intents: Array[ReminderIntent]
    # @rbs @outbound_message_intents: Array[OutboundMessageIntent]

    attr_reader :actor_id, :state

    # @rbs (actor_id: String, state: State) -> void
    def initialize(actor_id:, state:)
      @actor_id = actor_id
      @state = state
      @effect_intents = []
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
      unless rejection_code.match?(/\A[a-z][a-z0-9_]*\z/)
        raise ArgumentError, "rejection code must contain lowercase letters, digits, and underscores"
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
        success_message_name: on_success&.to_s,
        failure_message_name: on_failure&.to_s
      ).tap do |intent|
        effect_intents << intent
      end
      nil
    end

    # @rbs (Symbol | String, at: Time, ?every: Numeric?, ?missed: Symbol | String, arguments: Hash[Symbol | String, untyped]) -> nil
    def schedule(name, at:, every: nil, missed: :latest, arguments: {})
      interval_seconds = every&.to_f
      if interval_seconds && !interval_seconds.positive?
        raise ArgumentError, "reminder interval must be positive"
      end
      missed_policy = missed.to_s
      unless %w[all latest].include?(missed_policy)
        raise ArgumentError, "missed reminder policy must be all or latest"
      end

      ReminderIntent.new(
        name: name.to_s,
        at:,
        arguments: Serialization.dump(arguments),
        interval_seconds:,
        missed_policy:
      ).tap do |intent|
        reminder_intents << intent
      end
      nil
    end

    # @rbs (Reference, Symbol | String, ?available_at: Time?, ?idempotency_key: String?, **untyped) -> nil
    def send_to(reference, message_name, available_at: nil, idempotency_key: nil, **arguments)
      stage_outbound_message(reference, message_name, arguments, available_at:, idempotency_key:)
      nil
    end

    # @rbs (Symbol | String, Hash[String, untyped]) -> untyped
    def invoke(message_name, arguments)
      handler = self.class.definition.messages[message_name.to_sym] ||
        self.class.definition.queries[message_name.to_sym]
      raise UnknownMessage, "unknown message #{message_name.inspect} for #{self.class.actor_type}" unless handler

      instance_exec(**keyword_arguments(arguments), &handler.block)
    end

    # @rbs () -> Hash[String, untyped]
    def observable_values
      self.class.definition.observables.each_with_object({}) do |(name, handler), values|
        values[name.to_s] = Serialization.dump(instance_exec(&handler.block))
      end
    end

    # @rbs () -> void
    def activate
      self.class.definition.activation_hooks.each { |hook| instance_exec(&hook) }
    end

    # @rbs () -> void
    def deactivate
      self.class.definition.deactivation_hooks.each { |hook| instance_exec(&hook) }
    end

    # @rbs (Reference, Symbol | String, Hash[Symbol | String, untyped], ?available_at: Time?, idempotency_key: String?) -> OutboundMessageIntent
    def stage_outbound_message(reference, message_name, arguments, available_at: nil, idempotency_key: nil)
      OutboundMessageIntent.new(
        actor_type: reference.actor_type,
        actor_id: reference.actor_id,
        message_name: message_name.to_s,
        arguments: Serialization.dump(arguments),
        available_at:,
        idempotency_key:
      ).tap { |intent| outbound_message_intents << intent }
    end

    # @rbs () -> Array[EffectIntent]
    def drain_effect_intents
      effect_intents.shift(effect_intents.length)
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
      reminder_intents.clear
      outbound_message_intents.clear
    end

    private

    attr_reader :effect_intents, :reminder_intents, :outbound_message_intents

    # @rbs (Hash[String, untyped]) -> Hash[Symbol, untyped]
    def keyword_arguments(arguments)
      arguments.each_with_object({}) { |(key, value), converted| converted[key.to_sym] = value }
    end

    # @rbs (Symbol | String?) -> void
    def validate_effect_callback!(message_name)
      return unless message_name
      return if self.class.definition.messages.key?(message_name.to_sym)

      raise UnknownMessage, "unknown effect callback message #{message_name.inspect}"
    end
  end
end
