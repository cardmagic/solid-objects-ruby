# frozen_string_literal: true

require "database_test_helper"

class TransmissionTest < ActiveSupport::TestCase
  class CounterActor < SolidObjects::Actor
    actor_type "transmit-counters"

    attribute :value, default: 0

    def increment(amount: 1)
      self.value += amount
    end
  end

  FIXTURES = JSON.parse(
    File.read(File.expand_path("../../compatibility/transmit-envelopes.json", __dir__))
  )

  setup do
    SolidObjects.register_actor(CounterActor.actor_type, CounterActor)
  end

  def counter_state(actor_id)
    SolidObjects::Instance.find_by!(actor_type: "transmit-counters", actor_id:).state
  end

  def valid_envelope(overrides = {})
    {
      "effectId" => "effect-1",
      "actorType" => "transmit-counters",
      "actorId" => "alice",
      "operation" => "increment",
      "arguments" => { "amount" => 2 }
    }.merge(overrides)
  end

  test "enqueues an internal message the actor applies" do
    SolidObjects::Transmission.receive(valid_envelope)

    message = SolidObjects::Message.sole
    assert_equal "internal", message.delivery_mode
    assert_equal "increment", message.operation
    assert_equal({ "amount" => 2 }, message.arguments)
    assert_equal "transmit:effect-1", message.idempotency_key

    assert_equal 1, SolidObjects::Worker.new.run_until_idle
    assert_equal({ "value" => 2 }, counter_state("alice"))
  end

  test "applies a replayed envelope once" do
    envelope = valid_envelope
    first = SolidObjects::Transmission.receive(envelope)
    second = SolidObjects::Transmission.receive(envelope)

    assert_equal first.id, second.id
    assert_equal 1, SolidObjects::Message.count

    SolidObjects::Worker.new.run_until_idle

    assert_equal({ "value" => 2 }, counter_state("alice"))
  end

  test "defaults absent arguments to an empty object" do
    envelope = valid_envelope.except("arguments")

    SolidObjects::Transmission.receive(envelope)

    assert_equal({}, SolidObjects::Message.sole.arguments)
  end

  test "skips message authorization for the internal enqueue" do
    SolidObjects.configuration.authorize_message = ->(**) { false }

    SolidObjects::Transmission.receive(valid_envelope)

    assert_equal 1, SolidObjects::Message.count
  end

  test "maps a diverged actor type through resolve_actor_type" do
    envelope = valid_envelope("actorType" => "browser-counters")
    resolver = ->(actor_type) { actor_type.sub("browser-", "transmit-") }

    SolidObjects::Transmission.receive(envelope, resolve_actor_type: resolver)

    assert_equal "transmit-counters", SolidObjects::Message.sole.actor_type
  end

  test "rejects an unknown actor type" do
    assert_raises(SolidObjects::UnknownActorType) do
      SolidObjects::Transmission.receive(valid_envelope("actorType" => "missing"))
    end

    assert_empty SolidObjects::Message.all
  end

  test "rejects an unknown operation" do
    assert_raises(SolidObjects::UnknownMessage) do
      SolidObjects::Transmission.receive(valid_envelope("operation" => "erase"))
    end

    assert_empty SolidObjects::Message.all
  end

  test "enforces the payload byte cap" do
    SolidObjects.configuration.max_payload_bytes = 64
    envelope = valid_envelope("arguments" => { "note" => "x" * 200 })

    assert_raises(SolidObjects::PayloadTooLarge) do
      SolidObjects::Transmission.receive(envelope)
    end

    assert_empty SolidObjects::Message.all
  end

  test "rejects a non-object envelope" do
    [ nil, "envelope", [ valid_envelope ] ].each do |envelope|
      assert_raises(SolidObjects::InvalidTransmission) do
        SolidObjects::Transmission.receive(envelope)
      end
    end

    assert_empty SolidObjects::Message.all
  end

  test "rejects an envelope with a missing, blank, or non-string field" do
    [
      valid_envelope.except("effectId"),
      valid_envelope("effectId" => ""),
      valid_envelope("actorId" => ""),
      valid_envelope("operation" => 7),
      valid_envelope("actorType" => nil)
    ].each do |envelope|
      assert_raises(SolidObjects::InvalidTransmission) do
        SolidObjects::Transmission.receive(envelope)
      end
    end

    assert_empty SolidObjects::Message.all
  end

  test "rejects snake_case envelope keys" do
    envelope = {
      "effect_id" => "effect-1",
      "actor_type" => "transmit-counters",
      "actor_id" => "alice",
      "operation" => "increment"
    }

    assert_raises(SolidObjects::InvalidTransmission) do
      SolidObjects::Transmission.receive(envelope)
    end
  end

  test "rejects non-object arguments" do
    assert_raises(SolidObjects::InvalidTransmission) do
      SolidObjects::Transmission.receive(valid_envelope("arguments" => [ 1 ]))
    end
  end

  test "accepts every valid golden fixture envelope" do
    FIXTURES.fetch("valid").each do |fixture|
      reference = SolidObjects::Transmission.receive(fixture.fetch("envelope"))
      message = SolidObjects::Message.find(reference.id)

      assert_equal fixture.fetch("idempotencyKey"), message.idempotency_key,
        "fixture #{fixture.fetch("name").inspect}"
    end
  end

  test "rejects every malformed golden fixture envelope" do
    FIXTURES.fetch("malformed").each do |fixture|
      assert_raises(SolidObjects::InvalidTransmission, "fixture #{fixture.fetch("name").inspect}") do
        SolidObjects::Transmission.receive(fixture.fetch("envelope"))
      end
    end

    assert_empty SolidObjects::Message.all
  end

  test "applies the duplicate golden fixture pair once" do
    envelopes = FIXTURES.fetch("duplicatePair")

    references = envelopes.map do |envelope|
      SolidObjects::Transmission.receive(envelope)
    end

    assert_equal 1, references.map(&:id).uniq.length
  end
end
