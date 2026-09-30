# rbs_inline: enabled

require "database_test_helper"

class PayloadProjectionTest < ActiveSupport::TestCase
  class Reader < SolidObjects::Actor
    actor_type "payload-projection"
    attribute :items, default: []
    attribute :token, default: -> { SecureRandom.uuid }

    broadcast_payload :impure do |_actor, action|
      case action
      when "state" then items << "unexpected"
      when "effect" then emit :unexpected
      when "recovery" then request_effect_recovery("effect_id" => "missing-effect")
      when "commit_action" then commit_action :unexpected
      when "reminder" then schedule(at: Time.now + 60).append
      when "outbound" then send_to(self.class.ref("other")).append
      when "database" then SolidObjectsTestDomainRecord.create!(name: "unexpected")
      when "raise"
        items << "unexpected"
        raise "projection failed"
      end
      { "items" => items }
    end

    broadcast_payload(:pure) { { "items" => items } }
    broadcast_payload(:text) { |_actor, text| { "text" => text } }
    broadcast_payload(:defaults) { { "token" => token } }

    def append
      items << "committed"
    end
  end

  setup do
    Reader.ensure_registered!
  end

  %w[state effect recovery commit_action reminder outbound].each do |action|
    test "payload projections reject #{action}" do
      snapshot = SolidObjects::ActorSnapshot.new(Reader.ref("one"))

      assert_raises(SolidObjects::QueryMutatedState) { render(snapshot, "impure", action) }

      assert_empty snapshot.actor.state.to_h.fetch("items")
      assert_equal 0, snapshot.actor.intent_count
    end
  end

  test "payload projections prevent application database writes" do
    snapshot = SolidObjects::ActorSnapshot.new(Reader.ref("one"))

    assert_raises(SolidObjects::ApplicationWriteForbidden) { render(snapshot, "impure", "database") }

    assert_empty SolidObjectsTestDomainRecord.all
  end

  test "a raising payload cannot contaminate another projection of the same snapshot" do
    reference = Reader.ref("one")
    reference.append
    snapshot = SolidObjects::ActorSnapshot.new(reference)

    assert_raises(RuntimeError) { render(snapshot, "impure", "raise") }

    assert_equal({ "items" => [ "committed" ] }, render(snapshot, "pure").fetch("payload"))
    assert_equal [ "committed" ], snapshot.actor.state.to_h.fetch("items")
  end

  test "payload projections enforce the configured UTF-8 byte boundary" do
    snapshot = SolidObjects::ActorSnapshot.new(Reader.ref("one"))
    text = "éé"
    size = JSON.generate("text" => text).bytesize
    SolidObjects.configuration.max_payload_bytes = size

    assert_equal({ "text" => text }, render(snapshot, "text", text).fetch("payload"))

    SolidObjects.configuration.max_payload_bytes = size - 1
    assert_raises(SolidObjects::PayloadTooLarge) { render(snapshot, "text", text) }
  end

  test "payload projections share generated defaults from the original snapshot" do
    snapshot = SolidObjects::ActorSnapshot.new(Reader.ref("one"))
    expected = { "token" => snapshot.actor.token }

    assert_equal expected, render(snapshot, "defaults").fetch("payload")
    assert_equal expected, render(snapshot, "defaults").fetch("payload")
  end

  test "payload projections accept a configured limit above one megabyte" do
    snapshot = SolidObjects::ActorSnapshot.new(Reader.ref("one"))
    text = "x" * 1_048_576
    SolidObjects.configuration.max_payload_bytes = JSON.generate("text" => text).bytesize

    assert_equal text, render(snapshot, "text", text).fetch("payload").fetch("text")
  end

  private

  def render(snapshot, name, authorization_context = nil)
    SolidObjects::PayloadBroadcast.new(snapshot:, name:, authorization_context:).call
  end
end
