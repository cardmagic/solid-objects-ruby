# rbs_inline: enabled

module SolidObjects
  class Web
    # Declares the pages of the dashboard. Every route carries the
    # administration policy it needs, and a route declared without one raises
    # at load time. A new page therefore cannot reach the database before an
    # application has said who may read it.
    module Router
      # @rbs (String, policy: Hash[Symbol, String]?) { () -> untyped } -> void
      def head(path, policy: nil, &handler)
        route("HEAD", path, policy:, &handler)
      end

      # @rbs (String, policy: Hash[Symbol, String]?) { () -> untyped } -> void
      def get(path, policy: nil, &handler)
        route("GET", path, policy:, &handler)
      end

      # @rbs (String, policy: Hash[Symbol, String]?) { () -> untyped } -> void
      def post(path, policy: nil, &handler)
        route("POST", path, policy:, &handler)
      end

      # @rbs (String, String, policy: Hash[Symbol, String]?) { () -> untyped } -> void
      def route(request_method, path, policy: nil, &handler)
        raise ArgumentError, "route #{path} requires an authorization policy" unless policy
        raise ArgumentError, "route #{path} requires a handler" unless handler
        raise ArgumentError, "route #{path} requires a policy action" unless policy[:action]
        raise ArgumentError, "route #{path} requires a policy resource" unless policy[:resource]

        routes[request_method] << Route.new(request_method:, pattern: path, policy:, handler:)
      end

      # @rbs () -> Hash[String, Array[Route]]
      def routes
        @routes ||= Hash.new { |store, request_method| store[request_method] = [] }
      end

      # @rbs (String, String) -> Route?
      def match(request_method, path)
        routes[request_method].find { |route| route.match?(path) }
      end
    end
  end
end
