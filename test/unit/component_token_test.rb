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
