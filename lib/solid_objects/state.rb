# rbs_inline: enabled

module SolidObjects
  class StateDefinition
    Attribute = Data.define(:name, :default)

    # @rbs @attributes: Hash[Symbol, Attribute]

    # @rbs () -> void
    def initialize
      @attributes = {}
    end

    # @rbs (Symbol | String, ?default: untyped) -> Attribute
    def attribute(name, default: nil)
      attribute_name = name.to_sym
      raise InvalidActor, "state attribute #{attribute_name.inspect} is already defined" if attributes.key?(attribute_name)

      attributes[attribute_name] = Attribute.new(name: attribute_name, default:)
    end

    # @rbs () -> Hash[Symbol, Attribute]
    def to_h
      attributes.dup.freeze
    end

    # @rbs () -> StateDefinition
    def duplicate
      self.class.new.tap do |definition|
        attributes.each_value { |attribute| definition.attribute(attribute.name, default: attribute.default) }
      end
    end

    private

    attr_reader :attributes
  end

  class State
    # @rbs @definition: StateDefinition
    # @rbs @data: Hash[String, untyped]

    # @rbs (StateDefinition, Hash[String, untyped]?) -> void
    def initialize(definition, data = nil)
      @definition = definition
      @data = data ? Serialization.deep_copy(data) : {}
      apply_defaults
    end

    # @rbs () -> Hash[String, untyped]
    def to_h
      Serialization.deep_copy(data)
    end

    # @rbs (Symbol | String) -> untyped
    def fetch(name)
      key = name.to_s
      raise NoMethodError, "undefined state attribute #{name.inspect}" unless defined_attribute?(name)

      data.fetch(key)
    end

    # @rbs (Symbol | String, untyped) -> untyped
    def write(name, value)
      key = name.to_s
      raise NoMethodError, "undefined state attribute #{name.inspect}" unless defined_attribute?(name)

      data[key] = value
    end

    # @rbs (Symbol, *untyped) -> untyped
    def method_missing(name, *arguments)
      name_string = name.to_s

      if name_string.end_with?("=")
        attribute_name = name_string.delete_suffix("=")
        return write(attribute_name, arguments.fetch(0)) if arguments.one? && defined_attribute?(attribute_name)
      elsif arguments.empty? && defined_attribute?(name)
        return fetch(name)
      end

      super
    end

    # @rbs (Symbol, bool) -> bool
    def respond_to_missing?(name, include_private = false)
      attribute_name = name.to_s.delete_suffix("=")
      defined_attribute?(attribute_name) || super
    end

    private

    attr_reader :definition, :data

    # @rbs () -> void
    def apply_defaults
      definition.to_h.each_value do |attribute|
        key = attribute.name.to_s
        next if data.key?(key)

        value = attribute.default.respond_to?(:call) ? attribute.default.call : attribute.default
        data[key] = Serialization.deep_copy(value)
      end
    end

    # @rbs (Symbol | String) -> bool
    def defined_attribute?(name)
      definition.to_h.key?(name.to_sym)
    end
  end
end
