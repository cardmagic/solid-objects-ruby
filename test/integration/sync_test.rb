# frozen_string_literal: true

require "database_test_helper"

class SyncTest < ActiveSupport::TestCase
  class QueryActor < SolidObjects::Actor
    actor_type "sync-query"

    query :value do
      "answer"
    end
  end

  test "executes a query and returns its durable result" do
    result = QueryActor.ref("one").sync.value

    message = SolidObjects::Message.find_by!(actor_type: "sync-query", actor_id: "one")
    assert_equal "answer", result
    assert_equal "sync", message.delivery_mode
    assert message.completed?
    assert_equal "answer", message.result
  end

  test "uses query authorization" do
    SolidObjects.configuration.authorize_query = ->(**) { false }

    assert_raises(SolidObjects::Unauthorized) do
      QueryActor.ref("one").value
    end

    assert_empty SolidObjects::Message.all
  end
end
