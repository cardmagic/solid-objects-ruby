# frozen_string_literal: true

require "database_test_helper"
require "action_view/test_case"
require_relative "../../app/helpers/solid_objects/actor_helper"
require_relative "../../examples/application/app/actors/chat_room_actor"

class ExampleChatRoomTest < ActionView::TestCase
  tests SolidObjects::ActorHelper

  setup do
    SolidObjects.configuration.stream_signing_secret = "test-stream-signing-secret"
    SolidObjects.configuration.component_path_resolver = lambda do |view_context:|
      "/solid_objects/components"
    end
    ChatRoomActor.ensure_registered!
    @controller.prepend_view_path(
      File.expand_path("../../examples/application/app/views", __dir__)
    )
  end

  test "renders recent messages as a reactive ERB collection" do
    room = ChatRoomActor.ref("general")
    room.join(user_id: "alice")
    room.send_message(
      message_id: "message-1",
      user_id: "alice",
      body: "<Hello>"
    )

    html = solid_object(room, authorization_context: "alice") do |actor|
      actor.component(
        :messages,
        observes: :recent_messages,
        refresh: :morph
      )
    end

    assert_includes html, %(id="message_message-1")
    assert_includes html, "<strong>alice</strong>"
    assert_includes html, "&lt;Hello&gt;"
    refute_includes html, JSON.generate(room.snapshot.recent_messages)
    assert_equal 1, html.scan("<turbo-cable-stream-source").length
    assert_includes html, "solid_objects/component_refresh"
    assert_includes html, %(data-solid-objects-refresh="morph")
  end
end
