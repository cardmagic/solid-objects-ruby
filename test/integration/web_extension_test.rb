# frozen_string_literal: true

require "web_test_helper"

class WebExtensionTest < WebTestCase
  EXTENSION = Module.new do
    # @rbs (untyped) -> void
    def self.registered(application)
      application.get "/probe", policy: { action: "index", resource: "probe" } do
        erb(:_probe)
      end
    end
  end

  VIEWS = File.expand_path("../fixtures/web_extension", __dir__)

  setup do
    SolidObjects::Web.register(EXTENSION, tab: "Probe", path: "/probe", views: VIEWS)
  end

  teardown do
    SolidObjects::Web.reset!
  end

  test "serves a page the extension declared" do
    response = get("/probe")

    assert_equal 200, response.status
    assert_match(/probe page/, response.body)
  end

  test "adds the extension tab to every page" do
    assert_match(%r{href="/solid_objects/probe"}, get("/").body)
  end

  test "applies the administration policy to an extension route" do
    SolidObjects.configuration.authorize_administration = lambda do |resource:, **|
      resource != "probe"
    end

    assert_equal 403, get("/probe").status
  end

  test "prefers an extension view directory over the packaged one" do
    assert_match(/replaced summary/, get("/probe").body)
  end

  # Registered after the dashboard has already served a request, because the
  # built middleware stack is memoized and a late `use` would otherwise be
  # silently ignored.
  test "runs middleware an application put in front of the dashboard" do
    get("/")
    SolidObjects::Web.use(StampMiddleware)

    assert_equal "stamped", get("/").headers["x-probe"]
  end

  class StampMiddleware
    def initialize(app)
      @app = app
    end

    def call(env)
      status, headers, body = @app.call(env)
      [ status, headers.merge("x-probe" => "stamped"), body ]
    end
  end
end
