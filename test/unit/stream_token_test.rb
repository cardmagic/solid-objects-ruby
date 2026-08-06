# frozen_string_literal: true

require "database_test_helper"

class StreamTokenTest < ActiveSupport::TestCase
  class StreamActor < SolidObjects::Actor
    actor_type "stream-token"
  end

  setup do
    SolidObjects.configuration.stream_signing_secret = "test-stream-signing-secret"
  end

  test "round trips a signed actor identity" do
    token = SolidObjects::StreamToken.generate(StreamActor.ref("actor-1"))

    assert_equal(
      { "actor_type" => "stream-token", "actor_id" => "actor-1" },
      SolidObjects::StreamToken.verify(token)
    )
  end

  test "rejects a modified token" do
    token = SolidObjects::StreamToken.generate(StreamActor.ref("actor-1"))

    assert_raises(SolidObjects::InvalidStreamToken) do
      SolidObjects::StreamToken.verify("#{token}modified")
    end
  end

  test "uses a stable opaque stream name and DOM identity" do
    reference = StreamActor.ref("actor-1")

    assert_equal SolidObjects::StreamName.for(reference), SolidObjects::StreamName.for(reference)
    refute_includes SolidObjects::StreamName.for(reference), reference.actor_id
    refute_includes SolidObjects::DomIdentity.scope(reference), reference.actor_id
    assert_match(/\Asolid_objects_stream_[a-f0-9]{32}\z/, SolidObjects::StreamName.for(reference))
  end
end
