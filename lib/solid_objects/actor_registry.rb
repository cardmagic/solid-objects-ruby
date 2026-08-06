# rbs_inline: enabled

module SolidObjects
  class ActorRegistry
    # @rbs @actors: Hash[String, Class]
    # @rbs @mutex: Mutex

    # @rbs () -> void
    def initialize
      @actors = {}
      @mutex = Mutex.new
    end

    # @rbs (String | Symbol, Class) -> Class
    def register(type, actor_class)
      actor_type = normalize(type)
      validate_actor_class!(actor_class)

      mutex.synchronize do
        existing = actors[actor_type]
        if existing && existing != actor_class
          raise InvalidActor, "#{actor_type.inspect} is already registered by #{existing.name}"
        end

        actors[actor_type] = actor_class
      end

      actor_class
    end

    # @rbs (String | Symbol) -> Class
    def fetch(type)
      actor_type = normalize(type)
      actors.fetch(actor_type) { raise UnknownActorType, "unknown actor type #{actor_type.inspect}" }
    end

    # @rbs (String | Symbol) -> bool
    def registered?(type)
      actors.key?(normalize(type))
    end

    # @rbs () -> Hash[String, Class]
    def to_h
      mutex.synchronize { actors.dup.freeze }
    end

    private

    attr_reader :actors, :mutex

    # @rbs (String | Symbol) -> String
    def normalize(type)
      type.to_s.tap do |value|
        raise InvalidActor, "actor type cannot be empty" if value.empty?
      end
    end

    # @rbs (untyped) -> void
    def validate_actor_class!(actor_class)
      return if actor_class.is_a?(Class) && actor_class < Actor

      raise InvalidActor, "registered actor must inherit from SolidObjects::Actor"
    end
  end
end
