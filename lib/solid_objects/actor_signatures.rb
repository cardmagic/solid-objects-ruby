# rbs_inline: enabled

require "solid_objects"
require "rbs"
require "pathname"

module SolidObjects
  class ActorSignatures
    # @rbs (actors: Array[Class], signatures: Array[String]) -> String
    def self.generate(actors:, signatures:)
      new(signatures:).generate(actors:)
    end

    # @rbs @builder: untyped

    # @rbs (signatures: Array[String]) -> void
    def initialize(signatures:)
      loader = RBS::EnvironmentLoader.new
      loader.add(path: Pathname.new(File.expand_path("../../sig", __dir__)))
      signatures.sort.each { |path| loader.add(path: Pathname.new(path)) }
      environment = RBS::Environment.from_loader(loader).resolve_type_names
      @builder = RBS::DefinitionBuilder.new(env: environment)
    end

    # @rbs (actors: Array[Class]) -> String
    def generate(actors:)
      actors.uniq.sort_by { |actor| actor.name.to_s }.map { |actor| actor_signature(actor) }.join("\n")
    end

    private

    # @rbs (untyped) -> String
    def actor_signature(actor)
      unless actor < Actor && actor.name
        raise ArgumentError, "actor signatures require named SolidObjects::Actor subclasses"
      end

      name = RBS::TypeName.parse("::#{actor.name}")
      definition = @builder.build_instance(name)
      if definition.type_params.any?
        raise ArgumentError, "generic actor classes require application-owned dispatcher signatures"
      end
      messages = actor.definition.messages.keys.sort
      methods = messages.map do |operation|
        method = definition.methods[operation]
        unless method && method.accessibility == :public
          raise ArgumentError, "declare a public RBS signature for #{actor.name}##{operation}"
        end
        types = method.method_types.map { |type| staged_type(type, actor.name, operation).to_s }
        "    def #{operation}: #{types.join("\n      | ")}"
      end
      callback_names = messages.flat_map { |operation| [ operation.inspect, operation.to_s.inspect ] }
      callbacks = (callback_names + [ "nil" ]).join(" | ")
      <<~RBS
        class #{name}
          interface _SolidObjectsOperations
        #{methods.join("\n")}
            def public_send: (Symbol | String, **untyped) -> nil
          end

          def schedule: (at: Time, ?every: Numeric?, ?missed: Symbol | String, ?key: (String | Symbol | Integer)?) -> #{name}::_SolidObjectsOperations
          def transmit: () -> #{name}::_SolidObjectsOperations
          def emit: (Symbol | String, ?on_success: (#{callbacks}), ?on_failure: (#{callbacks}), **untyped) -> nil
        end
      RBS
    end

    # @rbs (untyped, String, Symbol) -> untyped
    def staged_type(method_type, actor_name, operation)
      function = method_type.type
      if !function.is_a?(RBS::Types::Function) || method_type.block ||
          function.required_positionals.any? || function.optional_positionals.any? ||
          function.rest_positionals || function.trailing_positionals.any?
        raise ArgumentError, "#{actor_name}##{operation} must declare keyword-only arguments without a block"
      end

      method_type.update(type: function.update(return_type: RBS::Types::Bases::Nil.new(location: nil)))
    end
  end
end
