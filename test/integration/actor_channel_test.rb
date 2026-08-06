# frozen_string_literal: true

require "database_test_helper"
require "action_cable/test_helper"
require "action_cable/channel/test_case"
require "solid_objects/actor_channel"

ActionCable.server.config.cable = { "adapter" => "test" }

class ActorChannelTest < ActionCable::Channel::TestCase
  tests SolidObjects::ActorChannel

  class ChannelActor < SolidObjects::Actor
    actor_type "channel-actor"

    attribute :missing, default: 0

    observable :missing
  end

  setup do
    SolidObjects.reset!
    ChannelActor.ensure_registered!
    SolidObjects.configuration.stream_signing_secret = "test-stream-signing-secret"
  end

  test "streams only after token verification and host authorization" do
    reference = ChannelActor.ref("actor-1")
    SolidObjects.configuration.authorize_subscription = lambda do |actor_type:, actor_id:, authorization_context:|
      actor_type == reference.actor_type &&
        actor_id == reference.actor_id &&
        authorization_context.current_user == "alice"
    end
    stub_connection(current_user: "alice")

    subscribe token: SolidObjects::StreamToken.generate(reference)

    assert subscription.confirmed?
    assert_has_stream SolidObjects::StreamName.for(reference)
    assert_equal 1, transmissions.length
    assert_includes transmissions.first, SolidObjects::DomIdentity.observable(reference, :missing)
  end

  test "rejects a valid token when host authorization fails" do
    reference = ChannelActor.ref("actor-1")
    SolidObjects.configuration.authorize_subscription = ->(**) { false }

    subscribe token: SolidObjects::StreamToken.generate(reference)

    assert subscription.rejected?
    assert_no_streams
  end

  test "rejects a tampered token" do
    reference = ChannelActor.ref("actor-1")
    SolidObjects.configuration.authorize_subscription = ->(**) { true }

    subscribe token: "#{SolidObjects::StreamToken.generate(reference)}tampered"

    assert subscription.rejected?
    assert_no_streams
  end
end
