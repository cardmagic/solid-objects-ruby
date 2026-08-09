# frozen_string_literal: true

require "database_test_helper"

class ComponentBatchTest < ActiveSupport::TestCase
  class BoardActor < SolidObjects::Actor
    actor_type "batch-board"

    attribute :player, default: "alice"
    attribute :controls, default: -> { [] }
    attribute :library, default: -> { [] }
    attribute :chat, default: -> { [] }

    observable :player
    observable :controls
    observable :library
    observable :chat
  end

  setup do
    BoardActor.ensure_registered!
    SolidObjects.configuration.stream_signing_secret = "batch-test-secret"
    SolidObjects.configuration.authorize_query = ->(**) { true }
  end

  test "components in one batch produce a single refresh element" do
    subscriptions = subscriptions_for(
      player: "playmat",
      controls: "playmat",
      library: "playmat"
    )

    streams = subscriptions.refreshes_for(invalidation("player"))

    assert_equal 1, streams.length
    assert_includes streams.first, "solid-objects-batch-refresh"
    assert_includes streams.first, %(data-batch="playmat")
  end

  test "the batch element carries only the components whose dependency changed" do
    subscriptions = subscriptions_for(
      player: "playmat",
      controls: "playmat",
      library: "playmat"
    )

    streams = subscriptions.refreshes_for(invalidation("player"))

    targets = streams.first[/data-targets="([^"]+)"/, 1].split
    assert_equal 1, targets.length
    assert_match(/player/, targets.first)
  end

  test "one batch element covers several components changing together" do
    subscriptions = subscriptions_for(
      player: "playmat",
      controls: "playmat"
    )
    combined = SolidObjects::ComponentSubscriptions.new(
      registrations(player: "playmat", controls: "playmat")
    )

    streams = combined.refreshes_for(invalidation("player")) +
      combined.refreshes_for(invalidation("controls"))

    assert_equal 2, streams.length
    assert(streams.all? { |stream| stream.include?("solid-objects-batch-refresh") })
    assert_equal 1, streams.map { |s| s[/data-revision="([^"]+)"/, 1] }.uniq.length
    refute_nil subscriptions
  end

  test "a stale revision produces no refresh" do
    subscriptions = subscriptions_for(player: "playmat")

    assert_empty subscriptions.refreshes_for(invalidation("player", revision: 0))
  end

  test "a repeated revision produces no second refresh" do
    subscriptions = subscriptions_for(player: "playmat")

    first = subscriptions.refreshes_for(invalidation("player"))
    second = subscriptions.refreshes_for(invalidation("player"))

    assert_equal 1, first.length
    assert_empty second
  end

  test "separate batches refresh independently" do
    subscriptions = SolidObjects::ComponentSubscriptions.new(
      registrations(player: "playmat", chat: "sidebar")
    )

    streams = subscriptions.refreshes_for(invalidation("player")) +
      subscriptions.refreshes_for(invalidation("chat"))

    batches = streams.map { |stream| stream[/data-batch="([^"]+)"/, 1] }
    assert_equal %w[playmat sidebar], batches
  end

  test "unbatched components keep the existing one-request behaviour" do
    subscriptions = SolidObjects::ComponentSubscriptions.new(
      registrations(player: nil, controls: nil)
    )

    streams = subscriptions.refreshes_for(invalidation("player"))

    assert_equal 1, streams.length
    refute_includes streams.first, "solid-objects-batch-refresh"
  end

  test "a batch mixes with unbatched components in one scope" do
    subscriptions = SolidObjects::ComponentSubscriptions.new(
      registrations(player: "playmat", controls: nil)
    )

    batched = subscriptions.refreshes_for(invalidation("player"))
    unbatched = subscriptions.refreshes_for(invalidation("controls"))

    assert_includes batched.first, "solid-objects-batch-refresh"
    refute_includes unbatched.first, "solid-objects-batch-refresh"
  end

  test "the batch name is signed into the component token" do
    registration = registrations(player: "playmat").first

    assert_equal "playmat", registration.batch
    assert_equal(
      "playmat",
      SolidObjects::ComponentRegistration.from_token(registration.token).batch
    )
  end

  test "rejects a forged batch name" do
    assert_raises SolidObjects::InvalidComponentToken do
      SolidObjects::ComponentToken.generate(
        reference: BoardActor.ref("table"),
        component_name: "player",
        component_key: nil,
        dependencies: %w[player],
        locals: {},
        refresh_method: "morph",
        instance_id: 1,
        revision: 1,
        refresh_path: "/solid_objects/components",
        batch: "not a batch"
      )
    end
  end

  test "the batch url requests every changed component once" do
    group = registrations(player: "playmat", controls: "playmat")

    url = group.first.batch_refresh_url(group, 5, 9)

    assert_includes url, "/solid_objects/components/batch?"
    assert_equal 2, url.scan("tokens%5B%5D=").length
    assert_includes url, "instance_id=5"
    assert_includes url, "revision=9"
  end

  private

  def reference
    BoardActor.ref("table")
  end

  def snapshot
    SolidObjects::ActorSnapshot.new(reference)
  end

  def registrations(**batches)
    current = snapshot
    batches.map do |component_name, batch|
      SolidObjects::ComponentRegistration.issue(
        reference:,
        component_name: component_name.to_s,
        component_key: nil,
        dependencies: [ component_name.to_s ],
        locals: {},
        refresh_method: "morph",
        snapshot: current,
        refresh_path: "/solid_objects/components",
        batch:
      )
    end
  end

  def subscriptions_for(**batches)
    SolidObjects::ComponentSubscriptions.new(registrations(**batches))
  end

  def invalidation(observable_name, revision: nil)
    current = snapshot
    {
      "observable_name" => observable_name.to_s,
      "instance_id" => current.instance_id,
      "revision" => revision || current.revision + 1
    }
  end
end
