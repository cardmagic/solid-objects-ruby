# frozen_string_literal: true

require "database_test_helper"
require "action_controller"
require "action_controller/test_case"
require "action_view"
require "action_view/testing/resolvers"
require_relative "../../app/controllers/solid_objects/components_controller"

class ComponentsControllerTest < ActionController::TestCase
  tests SolidObjects::ComponentsController

  class RoomActor < SolidObjects::Actor
    actor_type "component-room"

    attribute :recent_messages, default: -> { [] }
    attribute :status, default: "open"

    observable :recent_messages
    observable :status

    def replace_messages(messages:)
      self.recent_messages = messages
    end

    def update_room(messages:, status:)
      self.recent_messages = messages
      self.status = status
    end
  end

  setup do
    @routes = ActionDispatch::Routing::RouteSet.new
    @routes.draw do
      get "components", to: "solid_objects/components#show"
    end
    @controller.prepend_view_path(
      ActionView::FixtureResolver.new(
        "actors/components_controller_test/room_actor/_messages.html.erb" => <<~ERB,
          <p><%= authorization_context %></p>
          <ul>
            <% actor.recent_messages.each do |message| %>
              <li data-message-id="<%= message.fetch("id") %>"><%= message.fetch("body") %></li>
            <% end %>
          </ul>
        ERB
        "actors/components_controller_test/room_actor/_presence.html.erb" => <<~ERB,
          <% if actor.status == "closed" %>
            <p>Room closed</p>
          <% else %>
            <p><%= actor.recent_messages.length %> present</p>
          <% end %>
        ERB
        "actors/components_controller_test/room_actor/_player.html.erb" => <<~ERB
          <article data-player-id="<%= player_id %>" data-component-key="<%= component_key %>">
            <%= label %>: <%= actor.status %>
          </article>
        ERB
      )
    )
    SolidObjects.configuration.stream_signing_secret = "test-stream-signing-secret"
    SolidObjects.configuration.component_authorization_context = lambda do |controller:|
      controller.request.headers["HTTP_X_VIEWER"]
    end
    RoomActor.ensure_registered!
  end

  test "renders the latest collection addition removal and ordering" do
    reference = RoomActor.ref("general")
    reference.replace_messages(
      messages: [
        { id: "1", body: "First" },
        { id: "2", body: "Second" }
      ]
    )
    token = component_token(
      reference,
      component_name: "messages",
      dependencies: %w[recent_messages]
    )

    render_component(token, viewer: "alice")
    assert_ordered_messages("1", "2")

    reference.replace_messages(
      messages: [
        { id: "3", body: "Third" },
        { id: "1", body: "First" }
      ]
    )
    render_component(token, viewer: "alice")

    assert_ordered_messages("3", "1")
    refute_includes @response.body, "Second"
  end

  test "renders one or several observable dependencies" do
    reference = RoomActor.ref("general")
    reference.update_room(
      messages: [ { id: "1", body: "First" } ],
      status: "closed"
    )
    token = component_token(
      reference,
      component_name: "presence",
      dependencies: %w[recent_messages status]
    )

    render_component(token, viewer: "alice")

    assert_response :success
    assert_includes @response.body, "<p>Room closed</p>"
  end

  test "updates an ERB conditional after its dependency changes" do
    reference = RoomActor.ref("general")
    reference.update_room(messages: [], status: "open")
    token = component_token(
      reference,
      component_name: "presence",
      dependencies: %w[recent_messages status]
    )

    render_component(token, viewer: "alice")
    assert_includes @response.body, "<p>0 present</p>"

    reference.update_room(messages: [], status: "closed")
    render_component(token, viewer: "alice")
    assert_includes @response.body, "<p>Room closed</p>"
  end

  test "reauthorizes every component refresh" do
    reference = RoomActor.ref("general")
    token = component_token(
      reference,
      component_name: "messages",
      dependencies: %w[recent_messages]
    )
    SolidObjects.configuration.authorize_query = ->(**) { false }

    render_component(token, viewer: "alice")

    assert_response :forbidden
    assert_empty @response.body
  end

  test "reauthorizes the component name before refresh dependencies" do
    reference = RoomActor.ref("general")
    token = component_token(
      reference,
      component_name: "messages",
      dependencies: %w[recent_messages]
    )
    authorization_calls = []
    SolidObjects.configuration.authorize_query = lambda do |**arguments|
      authorization_calls << arguments
      arguments.fetch(:operation) == "recent_messages"
    end

    render_component(token, viewer: "alice")

    assert_response :forbidden
    assert_equal [ "messages" ],
      authorization_calls.map { |arguments| arguments.fetch(:operation) }
  end

  test "renders personalized HTML independently for each authorized request" do
    reference = RoomActor.ref("general")
    token = component_token(
      reference,
      component_name: "messages",
      dependencies: %w[recent_messages]
    )

    render_component(token, viewer: "alice")
    alice_html = @response.body
    render_component(token, viewer: "bob")
    bob_html = @response.body

    assert_includes alice_html, "<p>alice</p>"
    refute_includes alice_html, "<p>bob</p>"
    assert_includes bob_html, "<p>bob</p>"
    refute_includes bob_html, "<p>alice</p>"
    assert_equal "private, no-store", @response.headers["Cache-Control"]
  end

  test "escapes user-provided strings through ERB" do
    reference = RoomActor.ref("general")
    reference.replace_messages(
      messages: [ { id: "1", body: "<script>alert('x')</script>" } ]
    )
    token = component_token(
      reference,
      component_name: "messages",
      dependencies: %w[recent_messages]
    )

    render_component(token, viewer: "alice")

    assert_includes @response.body, "&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt;"
    refute_includes @response.body, "<script>"
  end

  test "rejects malformed component tokens" do
    render_component("malformed", viewer: "alice")

    assert_response :bad_request
  end

  test "rejects a token for an unknown conventional component" do
    reference = RoomActor.ref("general")
    token = component_token(
      reference,
      component_name: "secrets",
      dependencies: %w[status]
    )

    render_component(token, viewer: "alice")

    assert_response :not_found
  end

  test "rejects a requested revision newer than committed state" do
    reference = RoomActor.ref("general")
    token = component_token(
      reference,
      component_name: "messages",
      dependencies: %w[recent_messages]
    )
    registration = SolidObjects::ComponentRegistration.from_token(token)
    @request.headers["HTTP_X_VIEWER"] = "alice"

    get :show, params: {
      token:,
      instance_id: registration.instance_id + 1,
      revision: registration.revision
    }

    assert_response :conflict
    assert_empty @response.body
  end

  test "renders signed keyed locals and passes them to authorization" do
    reference = RoomActor.ref("general")
    authorization_calls = []
    SolidObjects.configuration.authorize_query = lambda do |**arguments|
      authorization_calls << arguments
      arguments.fetch(:arguments).fetch("player_id") == "alice"
    end
    token = component_token(
      reference,
      component_name: "player",
      component_key: "alice",
      dependencies: %w[status],
      locals: {
        player_id: "alice",
        label: "You"
      }
    )

    render_component(token, viewer: "alice")

    assert_response :success
    assert_includes @response.body, %(data-player-id="alice")
    assert_includes @response.body, %(data-component-key="alice")
    assert_includes @response.body, "You: open"
    assert_equal 2, authorization_calls.length
    expected_arguments = {
      "player_id" => "alice",
      "label" => "You",
      "component_key" => "alice"
    }
    assert authorization_calls.all? { |arguments|
      arguments.fetch(:arguments) == expected_arguments
    }
  end

  test "returns morph metadata for a morph component refresh" do
    reference = RoomActor.ref("general")
    token = component_token(
      reference,
      component_name: "player",
      component_key: "alice",
      dependencies: %w[status],
      locals: { player_id: "alice", label: "You" },
      refresh_method: "morph"
    )

    render_component(token, viewer: "alice")

    assert_response :success
    assert_includes @response.body, %(data-solid-objects-refresh="morph")
  end

  test "instruments an authorized component refresh without its locals" do
    reference = RoomActor.ref("general")
    reference.replace_messages(messages: [ { id: "1", body: "First" } ])
    token = component_token(
      reference,
      component_name: "player",
      component_key: "alice",
      dependencies: %w[status],
      locals: { player_id: "alice", label: "You" },
      refresh_method: "morph"
    )
    event = capture_component_event { render_component(token, viewer: "alice") }

    assert_response :success
    assert_equal "component-room", event.payload.fetch(:actor_type)
    assert_equal "general", event.payload.fetch(:actor_id)
    assert_equal "player", event.payload.fetch(:component_name)
    assert_equal "alice", event.payload.fetch(:component_key)
    assert_equal %w[status], event.payload.fetch(:dependencies)
    assert_equal "morph", event.payload.fetch(:refresh_method)
    assert_equal "rendered", event.payload.fetch(:outcome)
    assert_equal(
      SolidObjects::Instance.find_by(actor_type: "component-room", actor_id: "general").state_revision,
      event.payload.fetch(:revision)
    )
    assert event.payload.fetch(:instance_id)
    assert event.duration
    refute event.payload.key?(:locals)
    refute event.payload.key?(:token)
  end

  test "instruments a denied component refresh" do
    reference = RoomActor.ref("general")
    SolidObjects.configuration.authorize_query = ->(**) { false }
    token = component_token(
      reference,
      component_name: "messages",
      dependencies: %w[recent_messages]
    )

    event = capture_component_event { render_component(token, viewer: "mallory") }

    assert_response :forbidden
    assert_equal "unauthorized", event.payload.fetch(:outcome)
    assert_equal "messages", event.payload.fetch(:component_name)
  end

  test "instruments a superseded component refresh" do
    reference = RoomActor.ref("general")
    token = component_token(
      reference,
      component_name: "messages",
      dependencies: %w[recent_messages]
    )
    registration = SolidObjects::ComponentRegistration.from_token(token)
    @request.headers["HTTP_X_VIEWER"] = "alice"

    event = capture_component_event do
      get :show, params: {
        token:,
        instance_id: registration.instance_id + 1,
        revision: registration.revision
      }
    end

    assert_response :conflict
    assert_equal "conflict", event.payload.fetch(:outcome)
  end

  test "instruments a rejected component token" do
    event = capture_component_event { render_component("malformed", viewer: "alice") }

    assert_response :bad_request
    assert_equal "invalid_token", event.payload.fetch(:outcome)
    refute event.payload.key?(:component_name)
  end

  private

  def capture_component_event
    event = nil
    subscription = ActiveSupport::Notifications.subscribe(
      "solid_objects.component.refreshed"
    ) { |notification| event = notification }
    yield
    event
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
  end

  def component_token(
    reference,
    component_name:,
    dependencies:,
    component_key: nil,
    locals: {},
    refresh_method: "replace"
  )
    instance = SolidObjects::Instance.find_by(
      actor_type: reference.actor_type,
      actor_id: reference.actor_id
    )
    SolidObjects::ComponentToken.generate(
      reference:,
      component_name:,
      component_key:,
      dependencies:,
      locals:,
      refresh_method:,
      instance_id: instance&.id || 0,
      revision: instance&.state_revision || 0,
      refresh_path: "/components"
    )
  end

  def render_component(token, viewer:)
    registration = SolidObjects::ComponentRegistration.from_token(token)
    @request.headers["HTTP_X_VIEWER"] = viewer
    get :show, params: {
      token:,
      instance_id: registration.instance_id,
      revision: registration.revision
    }
  rescue SolidObjects::InvalidComponentToken
    get :show, params: {
      token:,
      instance_id: 0,
      revision: 0
    }
  end

  def assert_ordered_messages(*ids)
    positions = ids.map do |id|
      @response.body.index(%(data-message-id="#{id}"))
    end

    assert positions.all?
    assert_equal positions.sort, positions
  end
end
