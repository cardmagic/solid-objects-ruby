# rbs_inline: enabled

require "erb"
require "rack/request"
require "rack/utils"

module SolidObjects
  class Web
    # One request. A route handler runs inside an instance of this class, so a
    # handler and the template it renders share the same helpers and the same
    # request.
    class Action
      include Helpers

      # @rbs @env: Hash[String, untyped]
      # @rbs @route: Route
      # @rbs @captures: Hash[Symbol, String?]
      # @rbs @request: untyped
      # @rbs @layout_rendered: bool
      # @rbs @response_status: Integer

      attr_reader :env, :route, :response_status

      # @rbs (env: Hash[String, untyped], route: Route) -> void
      def initialize(env:, route:)
        @env = env
        @route = route
        @captures = route.capture(env["PATH_INFO"].to_s)
        @layout_rendered = false
        @response_status = 200
      end

      # Sets the status a rendered page is served with. `halt` and `redirect`
      # stop the handler, so a page that must render its own body and still
      # report a failure needs this instead.
      # @rbs (Integer) -> void
      def status(code)
        @response_status = code
      end

      # @rbs () -> untyped
      def request
        @request ||= ::Rack::Request.new(env)
      end

      # @rbs () -> Hash[untyped, untyped]?
      def session
        env["rack.session"]
      end

      # @rbs (Symbol) -> String?
      def route_params(key)
        @captures[key]
      end

      # @rbs (String) -> untyped
      def url_params(key)
        request.params[key]
      end

      # @rbs () -> untyped
      def call
        instance_exec(&route.handler)
      end

      # The layout is rendered once per request. The flag is raised before the
      # page body runs so a partial the body renders returns its own fragment
      # rather than a second whole page. The layout reads the page it wraps
      # from `locals.fetch(:content)`.
      # @rbs (Symbol, ?Hash[Symbol, untyped]) -> String
      def erb(name, locals = {})
        return evaluate(Web.template(name), locals) if @layout_rendered

        @layout_rendered = true
        content = evaluate(Web.template(name), locals)
        evaluate(Web.template(:layout), { content: })
      end

      # @rbs (Integer, ?String) -> void
      def halt(status, body = ::Rack::Utils::HTTP_STATUS_CODES.fetch(status, "Error"))
        throw :halt, [ status, { "content-type" => "text/plain" }, [ body ] ]
      end

      # @rbs (String) -> void
      def redirect(path)
        throw :halt, [ 302, { "location" => path_to(path) }, [] ]
      end

      # @rbs (untyped) -> void
      def json(payload)
        throw :halt, [
          200,
          { "content-type" => "application/json", "cache-control" => "private, no-store" },
          [ JSON.generate(payload) ]
        ]
      end

      private

      # `locals` is a local variable of this method, so a template reads it by
      # name, and every helper is reachable because the template runs against
      # this object.
      # @rbs (untyped, Hash[Symbol, untyped]) -> String
      def evaluate(template, locals)
        template.result(binding)
      end
    end
  end
end
