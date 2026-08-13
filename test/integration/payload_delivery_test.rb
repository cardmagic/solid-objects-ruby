# frozen_string_literal: true

require "database_test_helper"
require "action_cable/test_helper"
require "action_cable/channel/test_case"

ActionCable.server.config.cable = { "adapter" => "test" }

# The payload path from a Cable subscription to a transmitted element had no
# coverage, which is how a raised payload block came to take the subscription
# down with it.
class PayloadDeliveryTest < ActionCable::Channel::TestCase
  tests SolidObjects::ActorChannel

  class RoomActor < SolidObjects::Actor
    actor_type "delivery-room"

    attribute :hands, default: -> { {} }
    attribute :turn, default: 1

    observable :turn

    broadcast_payload :room_state do |room, authorization|
      { "turn" => room.turn, "hand" => room.hand_for(authorization.session_id) }
    end

    broadcast_payload :spectator_state do |room, _authorization|
      { "turn" => room.turn }
    end

    # Reached through implicit self by the block below, which is what a payload
    # block written like every other actor block expects to be able to do.
    broadcast_payload :helper_state do
      { "hand" => hand_for("alice") }
    end

    broadcast_payload :broken_state do
      raise "payload exploded with secret-hand and secret-token"
    end

    # Fails its first attempt only, modelling a transient error such as a lock
    # timeout while reading state.
    broadcast_payload :flaky_state do
      self.class.attempts += 1
      raise "transient" if self.class.attempts == 1

      { "turn" => turn }
    end

    class << self
      attr_writer :attempts

      def attempts = @attempts ||= 0
    end

    def hand_for(session_id) = hands.fetch(session_id, [])

    def deal(session_id:, cards:)
      self.hands = hands.merge(session_id => cards)
    end

    def advance_turn
      self.turn += 1
    end
  end

  # Models an application authorization object: what a controller render would
  # pass, and what the Cable path should be able to produce too.
  class Authorization
    attr_reader :session_id

    def initialize(session_id)
      @session_id = session_id
    end
  end

  setup do
    SolidObjects.reset!
    RoomActor.attempts = 0
    RoomActor.ensure_registered!
    SolidObjects.configuration.stream_signing_secret = "payload-delivery-secret"
    SolidObjects.configuration.authorize_subscription = ->(**) { true }
    SolidObjects.configuration.authorize_message = ->(**) { true }
    SolidObjects.configuration.authorize_query = ->(**) { true }
    SolidObjects.configuration.component_path_resolver = ->(view_context:) { "/solid_objects/components" }
    ActionCable.server.config.logger = Logger.new(nil)
  end

  test "the payload authorization context is resolved before authorization runs" do
    reference = deal_to("alice")
    contexts = []
    SolidObjects.configuration.payload_authorization_context = lambda do |connection:|
      Authorization.new(connection.playmat_session_id)
    end
    SolidObjects.configuration.authorize_query = lambda do |**arguments|
      contexts << arguments.fetch(:authorization_context)
      true
    end
    stub_connection(playmat_session_id: "alice")

    subscribe token: payload_token(reference, %w[room_state])

    assert contexts.any?, "the payload path should have authorized"
    assert(contexts.all? { |context| context.is_a?(Authorization) },
      "authorize_query should receive the resolved context, not the raw connection")
  end

  test "the payload block receives the resolved authorization context" do
    reference = deal_to("alice", %w[Island Forest])
    SolidObjects.configuration.payload_authorization_context = lambda do |connection:|
      Authorization.new(connection.playmat_session_id)
    end
    stub_connection(playmat_session_id: "alice")

    subscribe token: payload_token(reference, %w[room_state])

    assert_equal %w[Island Forest], delivered_payload("room_state").fetch("hand")
  end

  test "the default resolver passes the connection through unchanged" do
    reference = deal_to("alice", %w[Island])
    received = []
    SolidObjects.configuration.authorize_query = lambda do |**arguments|
      received << arguments.fetch(:authorization_context)
      true
    end
    stub_connection(session_id: "alice")

    subscribe token: payload_token(reference, %w[spectator_state])

    assert(received.any? { |context| context.respond_to?(:session_id) },
      "without a resolver the connection itself must still arrive")
  end

  test "a resolver may also accept the payload name" do
    reference = deal_to("alice")
    names = []
    SolidObjects.configuration.payload_authorization_context = lambda do |connection:, payload_name:|
      names << payload_name
      Authorization.new(connection.playmat_session_id)
    end
    stub_connection(playmat_session_id: "alice")

    subscribe token: payload_token(reference, %w[room_state spectator_state])

    assert_equal %w[room_state spectator_state], names.uniq.sort
  end

  test "the payload block runs with the actor as its receiver" do
    reference = deal_to("alice", %w[Island])
    stub_connection(session_id: "alice")

    subscribe token: payload_token(reference, %w[helper_state])

    assert_equal %w[Island], delivered_payload("helper_state").fetch("hand"),
      "an actor instance method should be reachable through implicit self"
  end

  test "a raising payload block does not reject the subscription" do
    reference = deal_to("alice")
    stub_connection(session_id: "alice")

    subscribe token: payload_token(reference, %w[broken_state])

    assert subscription.confirmed?, "one failed payload must not take the stream down"
    assert_has_stream SolidObjects::StreamName.for(reference)
  end

  test "a raising payload block is instrumented" do
    reference = deal_to("alice")
    events = capture_failures do
      stub_connection(session_id: "alice")
      subscribe token: payload_token(reference, %w[broken_state])
    end

    assert_equal 1, events.length
    event = events.first
    assert_equal "delivery-room", event[:actor_type]
    assert_equal "broken_state", event[:payload_name]
    assert_equal "RuntimeError", event[:error_class]
  end

  test "the failure event carries no payload state" do
    reference = deal_to("alice", %w[secret-hand])
    events = capture_failures do
      stub_connection(session_id: "alice")
      subscribe token: payload_token(reference, %w[broken_state])
    end

    serialized = events.first.inspect
    refute_includes serialized, "secret-hand"
    refute_includes serialized, "secret-token"
  end

  test "a failing payload does not stop another payload from being delivered" do
    reference = deal_to("alice")
    stub_connection(session_id: "alice")

    subscribe token: payload_token(reference, %w[broken_state spectator_state])

    refute_nil delivered_payload("spectator_state"),
      "a later payload name must still be delivered"
  end

  test "a failing payload does not stop component refreshes on the same connection" do
    reference = deal_to("alice")
    stub_connection(session_id: "alice")
    subscribe(
      token: payload_token(reference, %w[broken_state]),
      components: JSON.generate([ component_token(reference, revision: 0) ])
    )
    transmissions.clear

    reference.advance_turn
    receive_latest_broadcast

    assert component_refreshes.any?,
      "component delivery must survive a failing payload on the same connection"
  end

  test "an unauthorized payload is skipped rather than delivered" do
    reference = deal_to("alice")
    SolidObjects.configuration.authorize_query = lambda do |**arguments|
      arguments.fetch(:operation) != "room_state"
    end
    stub_connection(session_id: "alice")

    subscribe token: payload_token(reference, %w[room_state spectator_state])

    assert_nil delivered_payload("room_state")
    refute_nil delivered_payload("spectator_state")
  end

  test "subscribing delivers the current payload" do
    reference = deal_to("alice")
    reference.advance_turn
    stub_connection(session_id: "alice")

    subscribe token: payload_token(reference, %w[spectator_state])

    assert_equal 2, delivered_payload("spectator_state").fetch("turn")
  end

  # A failed payload must not advance the delivery watermark, or the subscriber
  # never sees that revision: dedup would skip every later attempt at it, and
  # the actor may not mutate again for a long time.
  test "a payload that failed is retried at the same revision" do
    reference = deal_to("alice")
    reference.advance_turn
    stub_connection(session_id: "alice")
    subscribe token: payload_token(reference, %w[flaky_state])
    assert_nil delivered_payload("flaky_state"), "the first attempt should have failed"

    receive_latest_broadcast

    refute_nil delivered_payload("flaky_state"),
      "a failed payload must be retried rather than marked delivered"
  end

  test "a payload is not re-delivered at the same revision" do
    reference = deal_to("alice")
    stub_connection(session_id: "alice")
    subscribe token: payload_token(reference, %w[spectator_state])
    transmissions.clear

    reference.advance_turn
    receive_latest_broadcast
    delivered = payload_elements("spectator_state").length
    receive_latest_broadcast

    assert_equal delivered, payload_elements("spectator_state").length,
      "a repeated revision must not transmit the payload again"
  end

  # The one behaviour change, reported at the call site rather than as an
  # unexplained NoMethodError.
  test "a block relying on the old class receiver explains itself" do
    class_scoped = Class.new(SolidObjects::Actor) do
      actor_type "payload-class-receiver"
      attribute :value, default: 1
      observable :value
      def self.table_name = "legacy"
      broadcast_payload(:legacy) { { "table" => table_name } }
    end
    class_scoped.ensure_registered!
    reference = class_scoped.ref("one")

    error = assert_raises SolidObjects::InvalidPayloadBroadcast do
      SolidObjects::PayloadBroadcast.new(
        snapshot: SolidObjects::ActorSnapshot.new(reference),
        name: "legacy",
        authorization_context: Authorization.new("alice")
      ).call
    end

    assert_match(/actor instance/, error.message)
    assert_match(/table_name/, error.message)
  end

  test "an ordinary typo in a payload block is not blamed on the receiver" do
    typo_actor = Class.new(SolidObjects::Actor) do
      actor_type "payload-typo"
      attribute :value, default: 1
      observable :value
      broadcast_payload(:typo) { { "value" => valeu } }
    end
    typo_actor.ensure_registered!
    reference = typo_actor.ref("one")

    error = assert_raises NameError do
      SolidObjects::PayloadBroadcast.new(
        snapshot: SolidObjects::ActorSnapshot.new(reference),
        name: "typo",
        authorization_context: Authorization.new("alice")
      ).call
    end

    refute_kind_of SolidObjects::InvalidPayloadBroadcast, error,
      "a name the class cannot answer either is not the receiver change"
  end

  test "a payload block keeping the documented signature is unaffected" do
    reference = deal_to("alice", %w[Island Forest])
    stub_connection(session_id: "alice")

    subscribe token: payload_token(reference, %w[room_state])

    assert_equal %w[Island Forest], delivered_payload("room_state").fetch("hand"),
      "the two-argument form must keep working unchanged"
  end

  test "rejects a payload authorization context that cannot be called" do
    SolidObjects.configuration.payload_authorization_context = :not_callable

    assert_raises ArgumentError do
      SolidObjects.configuration.validate!
    end
  end

  private

  def deal_to(session_id, cards = %w[Island])
    RoomActor.ref("table").tap do |reference|
      reference.deal(session_id:, cards:)
    end
  end

  def payload_token(reference, payloads)
    SolidObjects::StreamToken.generate(reference, observables: [], payloads:)
  end

  def component_token(reference, revision:)
    SolidObjects::ComponentToken.generate(
      reference:,
      component_name: "summary",
      component_key: nil,
      dependencies: %w[turn],
      locals: {},
      refresh_method: "replace",
      instance_id: 0,
      revision:,
      refresh_path: "/solid_objects/components"
    )
  end

  def capture_failures
    events = []
    subscription = ActiveSupport::Notifications.subscribe(
      "solid_objects.payload_broadcast_failed"
    ) { |event| events << event.payload }
    yield
    events
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
  end

  def payload_elements(name)
    transmissions.select do |transmission|
      transmission.to_s.include?(%(data-name="#{name}"))
    end
  end

  # The element body is HTML-escaped on the way out, exactly as the browser
  # receives it.
  def delivered_payload(name)
    element = payload_elements(name).last
    return nil unless element

    body = element[%r{<solid-objects-payload[^>]*>(.*?)</solid-objects-payload>}m, 1]
    JSON.parse(CGI.unescapeHTML(body))
  end

  def component_refreshes
    target = SolidObjects::DomIdentity.component(RoomActor.ref("table"), "summary")
    transmissions.select do |transmission|
      transmission.to_s.include?(%(target="#{target}"))
    end
  end

  def receive_latest_broadcast
    worker = SolidObjects::Worker.new
    worker.run_until_idle
    broadcast = SolidObjects::Broadcast.order(:id).last
    subscription.__send__(
      :receive_broadcast,
      SolidObjects::TurboStreamRenderer.observable(broadcast)
    )
  ensure
    worker&.stop
  end
end
