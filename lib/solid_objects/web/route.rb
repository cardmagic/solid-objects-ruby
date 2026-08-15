# rbs_inline: enabled

module SolidObjects
  class Web
    class Route
      # A named segment stops at the next slash, so `/instances/:id` never
      # swallows `/instances/1/pause` and route order cannot hide a page.
      NAMED_SEGMENT = %r{/([^/]*):([^.:$/]+)}
      SEGMENT_CAPTURE = '/\1(?<\2>[^$/]+)'

      # @rbs @matcher: String | Regexp
      # @rbs @request_method: String
      # @rbs @pattern: String
      # @rbs @policy: Hash[Symbol, String]
      # @rbs @handler: Proc

      attr_reader :request_method, :pattern, :policy, :handler

      # @rbs (request_method: String, pattern: String, policy: Hash[Symbol, String], handler: Proc) -> void
      def initialize(request_method:, pattern:, policy:, handler:)
        @request_method = request_method
        @pattern = pattern
        @policy = policy
        @handler = handler
        @matcher = compile(pattern)
      end

      # @rbs (String) -> bool
      def match?(path)
        return @matcher == path if @matcher.is_a?(String)

        @matcher.match?(path)
      end

      # @rbs (String) -> Hash[Symbol, String?]
      def capture(path)
        return {} if @matcher.is_a?(String)

        match = @matcher.match(path)
        return {} unless match

        match.named_captures.transform_keys(&:to_sym)
      end

      private

      # @rbs (String) -> (String | Regexp)
      def compile(pattern)
        return pattern unless pattern.match?(NAMED_SEGMENT)

        Regexp.new("\\A#{pattern.gsub(NAMED_SEGMENT, SEGMENT_CAPTURE)}\\z")
      end
    end
  end
end
