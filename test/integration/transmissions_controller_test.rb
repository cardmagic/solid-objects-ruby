# frozen_string_literal: true

require "database_test_helper"
require "action_controller"
require "action_controller/test_case"
require_relative "../../app/controllers/solid_objects/transmissions_controller"

class TransmissionsControllerTest < ActionController::TestCase
  tests SolidObjects::TransmissionsController

  class CounterActor < SolidObjects::Actor
    actor_type "engine-transmit-counters"

    attribute :count, default: 0

    def increment(amount: 1)
      self.count += amount
    end
  end

  setup do
    @routes = ActionDispatch::Routing::RouteSet.new
    @routes.draw do
      post "transmit", to: "solid_objects/transmissions#create"
    end
    SolidObjects.register_actor(CounterActor.actor_type, CounterActor)
  end

  def allow_transmissions
    SolidObjects.configuration.authorize_transmission = ->(**) { true }
  end

  def valid_envelope(overrides = {})
    {
      "effectId" => "engine-effect-1",
      "actorType" => "engine-transmit-counters",
      "actorId" => "alice",
      "operation" => "increment",
      "arguments" => { "amount" => 2 }
    }.merge(overrides)
  end

  def post_envelope(envelope)
    post :create, body: envelope.is_a?(String) ? envelope : JSON.generate(envelope)
  end

  test "denies by default" do
    post_envelope(valid_envelope)

    assert_response :forbidden
    assert_empty SolidObjects::Message.all
  end

  test "passes the envelope and controller to the policy" do
    captured = nil
    SolidObjects.configuration.authorize_transmission = lambda do |envelope:, authorization_context:|
      captured = [ envelope, authorization_context ]
      false
    end

    post_envelope(valid_envelope)

    assert_response :forbidden
    assert_equal valid_envelope, captured.fetch(0)
    assert_kind_of SolidObjects::TransmissionsController, captured.fetch(1)
  end

  test "ingests an authorized envelope" do
    allow_transmissions

    post_envelope(valid_envelope)

    assert_response :ok
    message = SolidObjects::Message.sole
    assert_equal "internal", message.delivery_mode
    assert_equal "transmit:engine-effect-1", message.idempotency_key
    assert_equal({ "amount" => 2 }, message.arguments)
  end

  test "applies a replayed envelope once" do
    allow_transmissions

    post_envelope(valid_envelope)
    post_envelope(valid_envelope)

    assert_response :ok
    assert_equal 1, SolidObjects::Message.count
  end

  test "maps actor types through the configured resolver" do
    allow_transmissions
    SolidObjects.configuration.transmission_actor_type_resolver =
      ->(actor_type) { actor_type.sub("browser-", "engine-") }

    post_envelope(valid_envelope("actorType" => "browser-transmit-counters"))

    assert_response :ok
    assert_equal "engine-transmit-counters", SolidObjects::Message.sole.actor_type
  end

  test "rejects a malformed envelope" do
    allow_transmissions

    post_envelope(valid_envelope.except("effectId"))

    assert_response :unprocessable_entity
    assert_empty SolidObjects::Message.all
  end

  test "rejects an unknown operation" do
    allow_transmissions

    post_envelope(valid_envelope("operation" => "erase"))

    assert_response :unprocessable_entity
    assert_empty SolidObjects::Message.all
  end

  test "rejects a conflicting replay" do
    allow_transmissions

    post_envelope(valid_envelope)
    post_envelope(valid_envelope("arguments" => { "amount" => 999 }))

    assert_response :unprocessable_entity
    assert_equal 1, SolidObjects::Message.count
  end

  test "rejects a body that is not JSON" do
    allow_transmissions

    post_envelope("not json")

    assert_response :unprocessable_entity
    assert_empty SolidObjects::Message.all
  end

  test "rejects an oversized envelope" do
    allow_transmissions
    SolidObjects.configuration.max_payload_bytes = 64

    post_envelope(valid_envelope("arguments" => { "note" => "x" * 200 }))

    assert_response :unprocessable_entity
    assert_empty SolidObjects::Message.all
  end
end
