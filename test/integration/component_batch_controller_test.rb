# frozen_string_literal: true

require "database_test_helper"
require "action_controller"
require "action_controller/test_case"
require "action_view"
require "action_view/testing/resolvers"
require_relative "../../app/controllers/solid_objects/components_controller"

class ComponentBatchControllerTest < ActionController::TestCase
  tests SolidObjects::ComponentsController

  class PlaymatRoom < SolidObjects::Actor
    actor_type "batch-controller-playmat"

    attribute :player, default: "alice"
    attribute :controls, default: -> { %w[untap draw] }
    attribute :library, default: -> { %w[Island] }

    observable :player
    observable :controls
    observable :library

    def seat(player:)
      self.player = player
    end
  end

  setup do
    @routes = ActionDispatch::Routing::RouteSet.new
    @routes.draw do
      get "components", to: "solid_objects/components#show"
      get "components/batch", to: "solid_objects/components#batch"
    end
    @controller.prepend_view_path(
      ActionView::FixtureResolver.new(
        "actors/component_batch_controller_test/playmat_room/_player.html.erb" =>
          "<p data-player><%= actor.player %></p>",
        "actors/component_batch_controller_test/playmat_room/_controls.html.erb" =>
          "<ul><% actor.controls.each do |control| %><li><%= control %></li><% end %></ul>",
        "actors/component_batch_controller_test/playmat_room/_library.html.erb" =>
          "<div data-viewer=\"<%= authorization_context %>\" data-seat=\"<%= seat %>\"><%= actor.library.join(\",\") %></div>"
      )
    )
    SolidObjects.configuration.stream_signing_secret = "batch-controller-secret"
    SolidObjects.configuration.component_authorization_context = lambda do |controller:|
      controller.request.headers["HTTP_X_VIEWER"]
    end
    PlaymatRoom.ensure_registered!
  end

  test "renders an HTML ERB component through the JSON batch endpoint" do
    registrations = issue(player: %w[player])

    get_batch(registrations)

    assert_response :success
    assert_equal "application/json", response.media_type
    frame = json_body.fetch("frames").first
    assert_includes frame.fetch("html"), "data-player"
    assert_includes frame.fetch("html"), "alice"
  end

  test "renders several components in one batch" do
    registrations = issue(player: %w[player], controls: %w[controls])

    get_batch(registrations)

    assert_response :success
    frames = json_body.fetch("frames")
    assert_equal 2, frames.length
    assert_includes frames.first.fetch("html"), "data-player"
    assert_includes frames.last.fetch("html"), "<li>untap</li>"
  end

  test "renders a component with locals and dependencies" do
    registrations = issue(library: %w[library])

    get_batch(registrations)

    assert_response :success
    html = json_body.fetch("frames").first.fetch("html")
    assert_includes html, %(data-viewer="alice")
    assert_includes html, %(data-seat="north")
    assert_includes html, "Island"
  end

  test "the request format stays JSON while partials render as HTML" do
    registrations = issue(player: %w[player])

    get_batch(registrations)

    assert_equal "application/json", response.media_type
    assert_includes json_body.fetch("frames").first.fetch("html"), "<turbo-frame"
  end

  test "carries target, revision, and refresh method for each frame" do
    registrations = issue(player: %w[player], controls: %w[controls])

    get_batch(registrations)

    frames = json_body.fetch("frames")
    assert_equal registrations.map(&:dom_id), frames.map { |frame| frame.fetch("target") }
    assert(frames.all? { |frame| frame.fetch("refresh_method") == "morph" })
    assert(frames.all? { |frame| frame.fetch("revision").match?(/\A\d+:\d+\z/) })
  end

  test "returns not found for a component with no partial" do
    registrations = issue(missing: %w[player])

    get_batch(registrations)

    assert_response :not_found
  end

  test "returns bad request for an invalid token" do
    @request.headers["HTTP_X_VIEWER"] = "alice"
    @request.headers["Accept"] = "application/json"
    get :batch, params: { tokens: [ "forged" ], instance_id: 1, revision: 1 }

    assert_response :bad_request
  end

  test "returns forbidden when the viewer is not authorized" do
    SolidObjects.configuration.authorize_query = lambda do |**arguments|
      arguments.fetch(:authorization_context) == "alice"
    end
    registrations = issue(player: %w[player])

    get_batch(registrations, viewer: "mallory")

    assert_response :forbidden
  end

  test "returns conflict for a revision newer than committed state" do
    registrations = issue(player: %w[player])
    @request.headers["HTTP_X_VIEWER"] = "alice"
    @request.headers["Accept"] = "application/json"

    get :batch, params: {
      tokens: registrations.map(&:token),
      instance_id: registrations.first.instance_id + 1,
      revision: registrations.first.revision
    }

    assert_response :conflict
  end

  test "the authorization callback receives every registration in a batch" do
    received = nil
    SolidObjects.configuration.component_authorization_context = lambda do |controller:, registrations:|
      received = registrations
      controller.request.headers["HTTP_X_VIEWER"]
    end
    registrations = issue(player: %w[player], controls: %w[controls])

    get_batch(registrations)

    assert_response :success
    assert_equal %w[player controls], received.map(&:component_name)
  end

  test "the authorization callback receives one registration for a single refresh" do
    received = nil
    SolidObjects.configuration.component_authorization_context = lambda do |controller:, registrations:|
      received = registrations
      controller.request.headers["HTTP_X_VIEWER"]
    end
    registration = issue(player: %w[player]).first
    @request.headers["HTTP_X_VIEWER"] = "alice"

    get :show, params: {
      token: registration.token,
      instance_id: registration.instance_id,
      revision: registration.revision
    }

    assert_response :success
    assert_equal %w[player], received.map(&:component_name)
  end

  test "a callback accepting only controller keeps working" do
    seen = 0
    SolidObjects.configuration.component_authorization_context = lambda do |controller:|
      seen += 1
      controller.request.headers["HTTP_X_VIEWER"]
    end
    registrations = issue(player: %w[player], controls: %w[controls])

    get_batch(registrations)

    assert_response :success
    assert_equal 1, seen
    assert_includes json_body.fetch("frames").first.fetch("html"), "data-player"
  end

  test "a callback accepting keyword splat receives registrations" do
    received = nil
    SolidObjects.configuration.component_authorization_context = lambda do |**arguments|
      received = arguments[:registrations]
      arguments.fetch(:controller).request.headers["HTTP_X_VIEWER"]
    end
    registrations = issue(player: %w[player])

    get_batch(registrations)

    assert_response :success
    assert_equal %w[player], received.map(&:component_name)
  end

  test "single component refresh still renders HTML" do
    registration = issue(player: %w[player]).first
    @request.headers["HTTP_X_VIEWER"] = "alice"

    get :show, params: {
      token: registration.token,
      instance_id: registration.instance_id,
      revision: registration.revision
    }

    assert_response :success
    assert_equal "text/html", response.media_type
    assert_includes response.body, "data-player"
  end

  private

  def reference
    PlaymatRoom.ref("table")
  end

  def issue(**components)
    snapshot = SolidObjects::ActorSnapshot.new(reference)
    components.map do |component_name, dependencies|
      SolidObjects::ComponentRegistration.issue(
        reference:,
        component_name: component_name.to_s,
        component_key: nil,
        dependencies:,
        locals: (component_name.to_s == "library") ? { seat: "north" } : {},
        refresh_method: "morph",
        snapshot:,
        refresh_path: "/components",
        batch: "playmat"
      )
    end
  end

  # The browser module requests the batch with a JSON Accept header, which is
  # what makes Rails look for JSON partials.
  def get_batch(registrations, viewer: "alice")
    @request.headers["HTTP_X_VIEWER"] = viewer
    @request.headers["Accept"] = "application/json"
    get :batch, params: {
      tokens: registrations.map(&:token),
      instance_id: registrations.first.instance_id,
      revision: registrations.first.revision
    }
  end

  def json_body
    JSON.parse(response.body)
  end
end
