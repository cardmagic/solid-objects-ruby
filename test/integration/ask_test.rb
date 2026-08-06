# frozen_string_literal: true

require "database_test_helper"

class AskTest < ActiveSupport::TestCase
  class QueryActor < SolidObjects::Actor
    actor_type "ask-query"

    query :value do
      "answer"
    end
  end

  test "times out without cancelling the durable message" do
    assert_raises(SolidObjects::AskTimeout) do
      QueryActor.ref("one").ask(:value, timeout: 0.01)
    end

    message = SolidObjects::Message.find_by!(actor_type: "ask-query", actor_id: "one")
    assert_equal "ask", message.message_kind
    assert message.ready?
  end

  test "uses query authorization" do
    SolidObjects.configuration.authorize_query = ->(**) { false }

    assert_raises(SolidObjects::Unauthorized) do
      QueryActor.ref("one").ask(:value, timeout: 0.01)
    end

    assert_empty SolidObjects::Message.all
  end
end
