# frozen_string_literal: true

require "database_test_helper"
require "action_cable"
require "solid_objects/actor_channel"

class PayloadBroadcastTest < ActiveSupport::TestCase
  class Connection
    attr_reader :session_id

    def initialize(session_id)
      @session_id = session_id
    end
  end

  class RoomActor < SolidObjects::Actor
    actor_type "payload-room"

    attribute :hands, default: -> { {} }
    attribute :turn, default: 1

    observable :turn

    broadcast_payload :room_state do |room, authorization_context|
      {
        "turn" => room.turn,
        "hand" => room.hands.fetch(authorization_context.session_id, [])
      }
    end

    def deal(session_id:, cards:)
      self.hands = hands.merge(session_id => cards)
    end

    def advance_turn
      self.turn += 1
    end
  end

  setup do
    RoomActor.ensure_registered!
    SolidObjects.configuration.stream_signing_secret = "payload-test-secret"
    SolidObjects.configuration.authorize_query = ->(**) { true }
  end

  test "renders a payload personalized to the subscriber" do
    reference = RoomActor.ref("table")
    reference.deal(session_id: "alice", cards: %w[Island Forest])
    reference.deal(session_id: "mallory", cards: %w[Swamp])

    alice = payload_for(reference, "alice")
    mallory = payload_for(reference, "mallory")

    assert_equal %w[Island Forest], alice.fetch("payload").fetch("hand")
    assert_equal %w[Swamp], mallory.fetch("payload").fetch("hand")
  end

  test "never exposes another subscriber's private state" do
    reference = RoomActor.ref("table")
    reference.deal(session_id: "alice", cards: %w[Black Lotus])

    mallory = payload_for(reference, "mallory")

    refute_includes JSON.generate(mallory), "Black Lotus"
  end

  test "carries actor identity and a monotonic revision" do
    reference = RoomActor.ref("table")
    reference.advance_turn
    first = payload_for(reference, "alice")

    reference.advance_turn
    second = payload_for(reference, "alice")

    assert_equal "payload-room", first.fetch("actor_type")
    assert_equal "table", first.fetch("actor_id")
    assert_equal "room_state", first.fetch("name")
    assert_operator second.fetch("revision"), :>, first.fetch("revision")
    assert_equal first.fetch("instance_id"), second.fetch("instance_id")
  end

  test "refuses to render a payload the subscriber cannot query" do
    reference = RoomActor.ref("table")
    reference.advance_turn
    SolidObjects.configuration.authorize_query = lambda do |**arguments|
      arguments.fetch(:authorization_context).session_id == "alice"
    end

    assert_equal "alice", payload_for(reference, "alice").fetch("payload").keys.any? ? "alice" : nil
    assert_raises SolidObjects::Unauthorized do
      payload_for(reference, "mallory")
    end
  end

  test "rejects an unknown payload broadcast name" do
    reference = RoomActor.ref("table")
    reference.advance_turn

    assert_raises SolidObjects::UnknownPayloadBroadcast do
      SolidObjects::PayloadBroadcast.new(
        snapshot: SolidObjects::ActorSnapshot.new(reference),
        name: "not_a_payload",
        authorization_context: Connection.new("alice")
      ).call
    end
  end

  test "requires a JSON object or array" do
    scalar_actor = Class.new(SolidObjects::Actor) do
      actor_type "payload-scalar"
      attribute :value, default: 1
      broadcast_payload(:scalar) { |actor, _context| actor.value }

      def bump = self.value += 1
    end
    scalar_actor.ensure_registered!
    reference = scalar_actor.ref("one")
    reference.bump

    assert_raises SolidObjects::InvalidPayloadBroadcast do
      SolidObjects::PayloadBroadcast.new(
        snapshot: SolidObjects::ActorSnapshot.new(reference),
        name: "scalar",
        authorization_context: Connection.new("alice")
      ).call
    end
  end

  test "the stream token signs the payload subscription" do
    reference = RoomActor.ref("table")
    token = SolidObjects::StreamToken.generate(reference, payloads: %w[room_state])

    assert_equal %w[room_state], SolidObjects::StreamToken.verify(token).fetch("payloads")
    assert_raises SolidObjects::InvalidStreamToken do
      SolidObjects::StreamToken.verify("#{token}tampered")
    end
  end

  test "renders a turbo stream element carrying the payload" do
    reference = RoomActor.ref("table")
    reference.deal(session_id: "alice", cards: %w[Island])

    element = SolidObjects::TurboStreamRenderer.state_payload(
      payload_for(reference, "alice")
    )

    assert_includes element, "solid-objects-payload"
    assert_includes element, %(data-name="room_state")
    assert_match(/data-revision="\d+:\d+"/, element)
    assert_includes element, "Island"
  end

  test "actors without a payload broadcast are unaffected" do
    plain = Class.new(SolidObjects::Actor) do
      actor_type "payload-none"
      attribute :value, default: 0
      observable :value
    end

    assert_empty plain.definition.payload_broadcasts
  end

  private

  def payload_for(reference, session_id)
    SolidObjects::PayloadBroadcast.new(
      snapshot: SolidObjects::ActorSnapshot.new(reference),
      name: "room_state",
      authorization_context: Connection.new(session_id)
    ).call
  end
end
