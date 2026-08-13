# frozen_string_literal: true

require "database_test_helper"

class StateSnapshotTest < ActiveSupport::TestCase
  class SnapshotActor < SolidObjects::Actor
    actor_type "state-snapshot"

    attribute :items, default: -> { [] }
    attribute :status, default: "draft"

    def add_item(name:)
      items << { "name" => name }
    end
  end

  test "reads committed attributes without adding a mailbox message" do
    reference = SnapshotActor.ref("one")
    reference.add_item(name: "Book")
    message_count = SolidObjects::Message.count

    snapshot = reference.snapshot

    assert_equal "draft", snapshot.status
    assert_equal [ { "name" => "Book" } ], snapshot.items
    assert_equal(
      { "items" => [ { "name" => "Book" } ], "status" => "draft" },
      snapshot.to_h
    )
    assert_predicate snapshot.items, :frozen?
    assert_predicate snapshot.items.first, :frozen?
    assert_equal message_count, SolidObjects::Message.count
  end

  test "returns actor defaults without creating an instance" do
    snapshot = SnapshotActor.ref("missing").snapshot

    assert_equal [], snapshot.items
    assert_equal "draft", snapshot.status
    assert_empty SolidObjects::Instance.all
  end

  test "authorizes state snapshots as queries" do
    calls = []
    SolidObjects.configuration.authorize_query = ->(**arguments) do
      calls << arguments
      false
    end

    assert_raises(SolidObjects::Unauthorized) do
      SnapshotActor.ref("protected").snapshot(authorization_context: :request)
    end

    assert_predicate calls, :one?
    assert_equal "__snapshot__", calls.first.fetch(:operation)
    assert_equal :request, calls.first.fetch(:authorization_context)
  end

  test "mutable copy returns independently mutable JSON data" do
    snapshot = SnapshotActor.ref("one").snapshot

    items = SolidObjects.mutable_copy(snapshot.items)
    items << { "name" => "Book" }

    assert_equal [ { "name" => "Book" } ], items
    assert_empty snapshot.items
  end
end
