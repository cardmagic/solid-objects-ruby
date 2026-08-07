# frozen_string_literal: true

require "database_test_helper"

class ComponentTokenTest < ActiveSupport::TestCase
  class RoomActor < SolidObjects::Actor
    actor_type "component-token-room"

    attribute :messages, default: -> { [] }

    observable :messages
  end

  setup do
    SolidObjects.configuration.stream_signing_secret = "test-stream-signing-secret"
    RoomActor.ensure_registered!
  end

  test "round trips a constrained component registration" do
    reference = RoomActor.ref("general")
    token = SolidObjects::ComponentToken.generate(
      reference:,
      component_name: "messages",
      dependencies: %w[messages],
      instance_id: 12,
      revision: 34,
      refresh_path: "/solid_objects/components"
    )

    registration = SolidObjects::ComponentRegistration.from_token(token)

    assert_equal reference.actor_type, registration.reference.actor_type
    assert_equal reference.actor_id, registration.reference.actor_id
    assert_equal "messages", registration.component_name
    assert_equal %w[messages], registration.dependencies
    assert_equal [ 12, 34 ], registration.revision_key
    assert_match(
      %r{\A/solid_objects/components\?},
      registration.refresh_url(12, 35)
    )
  end

  test "round trips keyed component locals and morph refresh metadata" do
    reference = RoomActor.ref("general")
    token = SolidObjects::ComponentToken.generate(
      reference:,
      component_name: "player",
      component_key: "alice",
      dependencies: %w[messages],
      locals: {
        player_id: "alice",
        seat: 1
      },
      refresh_method: "morph",
      instance_id: 12,
      revision: 34,
      refresh_path: "/solid_objects/components"
    )

    registration = SolidObjects::ComponentRegistration.from_token(token)

    assert_equal "alice", registration.component_key
    assert_equal(
      {
        "player_id" => "alice",
        "seat" => 1
      },
      registration.locals
    )
    assert_equal "morph", registration.refresh_method
    assert_match(/_component_player_/, registration.dom_id)
    refute_includes registration.dom_id, "alice"
  end

  test "rejects invalid component keys locals and refresh methods" do
    invalid_options = [
      { component_key: true },
      { locals: { actor: "shadowed" } },
      { locals: { "invalid-name" => "value" } },
      { refresh_method: "append" }
    ]

    invalid_options.each do |options|
      assert_raises(SolidObjects::InvalidComponentToken) do
        SolidObjects::ComponentToken.generate(
          reference: RoomActor.ref("general"),
          component_name: "messages",
          dependencies: %w[messages],
          instance_id: 0,
          revision: 0,
          refresh_path: "/solid_objects/components",
          **options
        )
      end
    end
  end

  test "accepts component tokens issued before keyed components" do
    payload = {
      "actor_type" => "component-token-room",
      "actor_id" => "general",
      "component_name" => "messages",
      "dependencies" => %w[messages],
      "instance_id" => 12,
      "revision" => 34,
      "refresh_path" => "/solid_objects/components"
    }
    verifier = ActiveSupport::MessageVerifier.new(
      "test-stream-signing-secret",
      digest: "SHA256",
      serializer: JSON
    )
    token = verifier.generate(
      payload,
      purpose: SolidObjects::ComponentToken::PURPOSE
    )

    registration = SolidObjects::ComponentRegistration.from_token(token)

    assert_nil registration.component_key
    assert_empty registration.locals
    assert_equal "replace", registration.refresh_method
  end

  test "rejects modified tokens" do
    token = valid_token

    assert_raises(SolidObjects::InvalidComponentToken) do
      SolidObjects::ComponentRegistration.from_token("#{token}modified")
    end
  end

  test "rejects unknown observable dependencies" do
    token = SolidObjects::ComponentToken.generate(
      reference: RoomActor.ref("general"),
      component_name: "messages",
      dependencies: %w[private_messages],
      instance_id: 0,
      revision: 0,
      refresh_path: "/solid_objects/components"
    )

    assert_raises(SolidObjects::InvalidComponentToken) do
      SolidObjects::ComponentRegistration.from_token(token)
    end
  end

  test "rejects external and protocol-relative refresh paths" do
    [ "https://example.com/components", "//example.com/components" ].each do |refresh_path|
      assert_raises(SolidObjects::InvalidComponentToken) do
        SolidObjects::ComponentToken.generate(
          reference: RoomActor.ref("general"),
          component_name: "messages",
          dependencies: %w[messages],
          instance_id: 0,
          revision: 0,
          refresh_path:
        )
      end
    end
  end

  private

  def valid_token
    SolidObjects::ComponentToken.generate(
      reference: RoomActor.ref("general"),
      component_name: "messages",
      dependencies: %w[messages],
      instance_id: 0,
      revision: 0,
      refresh_path: "/solid_objects/components"
    )
  end
end
