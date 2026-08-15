# frozen_string_literal: true

require "test_helper"
require "solid_objects/web"

class WebRouterTest < ActiveSupport::TestCase
  class Routes
    extend SolidObjects::Web::Router

    get "/", policy: { action: "index", resource: "dashboard" } do
      "root"
    end

    get "/instances/:id", policy: { action: "show", resource: "instances" } do
      "instance #{route_params(:id)}"
    end

    post "/instances/:id/pause", policy: { action: "pause", resource: "instances" } do
      "paused"
    end
  end

  test "matches a static path" do
    route = Routes.match("GET", "/")

    assert_equal "/", route.pattern
  end

  test "matches a named segment and captures it" do
    route = Routes.match("GET", "/instances/42")

    assert_equal({ id: "42" }, route.capture("/instances/42"))
  end

  test "separates routes by request method" do
    assert_nil Routes.match("POST", "/instances/42")
    assert Routes.match("POST", "/instances/42/pause")
  end

  test "does not match a named segment across a slash" do
    assert_nil Routes.match("GET", "/instances/42/pause")
  end

  test "carries the authorization policy of the matched route" do
    route = Routes.match("POST", "/instances/42/pause")

    assert_equal "pause", route.policy.fetch(:action)
    assert_equal "instances", route.policy.fetch(:resource)
  end

  test "refuses a route declared without an authorization policy" do
    error = assert_raises(ArgumentError) do
      Class.new { extend SolidObjects::Web::Router }.get("/open") { "open" }
    end

    assert_match(/policy/, error.message)
  end
end
