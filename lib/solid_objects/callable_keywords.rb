# rbs_inline: enabled

module SolidObjects
  # Authorization context resolvers gained keywords after applications had
  # already written them, so a resolver is called with what it declared it
  # accepts rather than with everything the caller could offer.
  module CallableKeywords
    class << self
      # @rbs (untyped, Symbol) -> bool
      def accepts?(callable, keyword)
        parameters(callable).any? do |type, name|
          type == :keyrest || (%i[key keyreq].include?(type) && name == keyword)
        end
      end

      private

      # A lambda answers `parameters` directly; a callable object answers it
      # through its `call` method.
      # @rbs (untyped) -> Array[[ Symbol, Symbol ]]
      def parameters(callable)
        return callable.parameters if callable.respond_to?(:parameters)
        return callable.method(:call).parameters if callable.respond_to?(:call)

        []
      end
    end
  end
end
