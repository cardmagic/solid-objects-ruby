# rbs_inline: enabled

require "erb"
require "json"
require "securerandom"
require "uri"
require "rack"
require "rack/builder"
require "rack/static"

require "solid_objects"
require "solid_objects/web/route"
require "solid_objects/web/router"
require "solid_objects/web/statistics"
require "solid_objects/web/paginator"
require "solid_objects/web/helpers"
require "solid_objects/web/action"
require "solid_objects/web/csrf_protection"
require "solid_objects/web/application"

module SolidObjects
  # An operator dashboard for the actor runtime, served as a Rack application:
  #
  #   Rails.application.routes.draw do
  #     mount SolidObjects::Web => "/solid_objects"
  #   end
  #
  # It is deliberately not loaded by `require "solid_objects"`. A worker
  # process must not carry a web stack, and an application that never mounts
  # the dashboard must not pay for it.
  #
  # Every page asks `configuration.authorize_administration` first. That block
  # denies by default, so a mount alone exposes nothing until an application
  # states who may read it.
  class Web
    ROOT = File.expand_path("../../web", __dir__)
    VIEWS = File.join(ROOT, "views")
    ASSETS = File.join(ROOT, "assets")

    NONCE_KEY = "solid_objects.content_security_policy_nonce"
    CSRF_TOKEN_KEY = "solid_objects.csrf_token"
    NONCE_BYTES = 16
    ASSET_CACHE_SECONDS = 86_400
    TEMPLATE_NAME = /\A_?[a-z][a-z0-9_]*\z/

    # The dashboard charts need a charting library, and this one is fetched
    # from a public CDN with a subresource integrity hash, so a compromised CDN
    # cannot substitute other code. A deployment with no outbound network
    # access should vendor the file and point `chart_library_url` at it, or set
    # that to nil to render the dashboard without charts.
    CHART_LIBRARY_URL = "https://cdn.jsdelivr.net/npm/chart.js@4.5.0/dist/chart.umd.min.js"
    CHART_LIBRARY_INTEGRITY = "sha384-XcdcwHqIPULERb2yDEM4R0XaQKU3YnDsrTmjACBZyfdVVqjh6xQ4/DCMd7XLcA6Y"

    DEFAULT_TABS = {
      "Dashboard" => "/",
      "Instances" => "/instances",
      "Mailbox" => "/mailbox",
      "Reminders" => "/reminders",
      "Effects" => "/effects",
      "Broadcasts" => "/broadcasts",
      "Dead letters" => "/dead_letters",
      "Processes" => "/processes"
    }.freeze

    LOCK = Mutex.new

    class << self
      # A path below the mount serves a vendored copy; an absolute URL is
      # fetched from that host and is named in the content security policy.
      # nil renders the dashboard without charts.
      # @rbs @chart_library_url: String?
      # @rbs @chart_library_integrity: String?
      attr_writer :chart_library_url, :chart_library_integrity

      # @rbs () -> String?
      def chart_library_url
        defined?(@chart_library_url) ? @chart_library_url : CHART_LIBRARY_URL
      end

      # @rbs () -> String?
      def chart_library_integrity
        defined?(@chart_library_integrity) ? @chart_library_integrity : CHART_LIBRARY_INTEGRITY
      end

      # @rbs () -> bool
      def charts?
        !chart_library_url.nil?
      end

      # The origin the content security policy has to allow. A vendored copy
      # served from the mount has none, so the policy stays at 'self'.
      # @rbs () -> String?
      def chart_library_origin
        url = chart_library_url
        return nil unless url&.include?("//")

        uri = URI.parse(url)
        return nil unless uri.scheme && uri.host

        "#{uri.scheme}://#{uri.host}"
      rescue URI::InvalidURIError
        nil
      end

      # @rbs () -> Hash[String, String]
      def tabs
        @tabs ||= DEFAULT_TABS.dup
      end

      # Searched in order, so an extension directory added first wins over the
      # packaged one and an application can replace a single page.
      # @rbs () -> Array[String]
      def views
        @views ||= [ VIEWS ]
      end

      # @rbs () -> Array[[Array[untyped], Proc?]]
      def middlewares
        @middlewares ||= []
      end

      # The built stack is memoized, so a middleware added after the first
      # request would otherwise be dropped without a word.
      # @rbs (*untyped) ?{ () -> untyped } -> void
      def use(*arguments, &block)
        middlewares << [ arguments, block ]
        LOCK.synchronize { @application = nil }
      end

      # Adds pages to the dashboard. The extension receives the application
      # class and declares its own routes on it, which means its routes carry
      # an authorization policy like every other route.
      #
      # @rbs (untyped, tab: String, path: String, ?views: String?) -> void
      def register(extension, tab:, path:, views: nil)
        if views
          self.views.unshift(views)
          # A template compiled before this call resolved against the old
          # search path, so a replacement view would never be reached.
          LOCK.synchronize { @templates = {} }
        end
        tabs[tab] = path
        extension.registered(Application)
      end

      # @rbs (Symbol) -> untyped
      def template(name)
        LOCK.synchronize do
          templates[name] ||= ERB.new(File.read(template_path(name)), trim_mode: "-")
        end
      end

      # @rbs () -> void
      def reset!
        LOCK.synchronize { @templates = {} }
        @tabs = nil
        @views = nil
        @middlewares = nil
        @application = nil
        remove_instance_variable(:@chart_library_url) if defined?(@chart_library_url)
        remove_instance_variable(:@chart_library_integrity) if defined?(@chart_library_integrity)
      end

      # @rbs (Hash[String, untyped]) -> Array[untyped]
      def call(env)
        application.call(env)
      end

      # @rbs () -> Web
      def application
        LOCK.synchronize { @application ||= new }
      end

      private

      # @rbs () -> Hash[Symbol, untyped]
      def templates
        @templates ||= {}
      end

      # A template name never comes from a request, and this keeps it that way
      # rather than trusting every future caller to know it.
      # @rbs (Symbol) -> String
      def template_path(name)
        raise ArgumentError, "invalid template name" unless name.to_s.match?(TEMPLATE_NAME)

        found = views.lazy.map { |directory| File.join(directory, "#{name}.erb") }.find { |path| File.exist?(path) }
        found || raise(ArgumentError, "no template named #{name}")
      end
    end

    # @rbs (Hash[String, untyped]) -> Array[untyped]
    def call(env)
      env[NONCE_KEY] = SecureRandom.base64(NONCE_BYTES)
      app.call(env)
    end

    # @rbs () -> untyped
    def app
      @app ||= build
    end

    private

    # @rbs () -> untyped
    def build
      assets = ASSETS
      extra = self.class.middlewares

      ::Rack::Builder.new do
        use ::Rack::Static,
          urls: [ "/stylesheets", "/javascripts" ],
          root: assets,
          cascade: true,
          header_rules: [ [ :all, { "cache-control" => "private, max-age=#{ASSET_CACHE_SECONDS}" } ] ]
        extra.each { |arguments, block| use(*arguments, &block) }
        use CsrfProtection
        run Application.new
      end
    end
  end
end
