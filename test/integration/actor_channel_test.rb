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
    attribute :status, default: "open"
    attribute :unrelated, default: 0

    observable :missing
    observable :status
    observable :unrelated

    def update_all
      self.missing += 1
      self.status = "closed"
      self.unrelated += 1
    end

    def update_missing
      self.missing += 1
    end
  end

  setup do
    SolidObjects.reset!
    ChannelActor.ensure_registered!
    SolidObjects.configuration.stream_signing_secret = "test-stream-signing-secret"
    SolidObjects.configuration.authorize_message = ->(**) { true }
    SolidObjects.configuration.authorize_query = ->(**) { true }
    ActionCable.server.config.logger = Logger.new(nil)
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
    assert_equal 3, transmissions.length
    assert(transmissions.any? do |transmission|
      transmission.include?(SolidObjects::DomIdentity.observable(reference, :missing))
    end)
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

  test "refreshes a component once when several dependencies change in one turn" do
    reference = ChannelActor.ref("actor-1")
    SolidObjects.configuration.authorize_subscription = ->(**) { true }
    subscribe(
      token: SolidObjects::StreamToken.generate(reference),
      components: JSON.generate(
        [
          component_token(
            reference,
            component_name: "summary",
            dependencies: %w[missing status],
            revision: 0
          )
        ]
      )
    )
    ChannelActor.ref("actor-1").async(:update_all)
    worker = SolidObjects::Worker.new
    worker.run_until_idle

    SolidObjects::Broadcast.where(observable_name: %w[missing status]).find_each do |broadcast|
      subscription.__send__(
        :receive_broadcast,
        SolidObjects::TurboStreamRenderer.observable(broadcast)
      )
    end

    assert_equal 1, component_refreshes(reference, :summary).length
  ensure
    worker&.stop
  end

  test "does not refresh a component for an unrelated observable" do
    reference = ChannelActor.ref("actor-1")
    SolidObjects.configuration.authorize_subscription = ->(**) { true }
    subscribe(
      token: SolidObjects::StreamToken.generate(reference),
      components: JSON.generate(
        [
          component_token(
            reference,
            component_name: "summary",
            dependencies: %w[status],
            revision: 0
          )
        ]
      )
    )
    ChannelActor.ref("actor-1").async(:update_missing)
    worker = SolidObjects::Worker.new
    worker.run_until_idle
    broadcast = SolidObjects::Broadcast.find_by!(observable_name: "missing")

    subscription.__send__(
      :receive_broadcast,
      SolidObjects::TurboStreamRenderer.observable(broadcast)
    )

    assert_empty component_refreshes(reference, :summary)
  ensure
    worker&.stop
  end

  test "does not transmit component dependency values as scalar updates" do
    reference = ChannelActor.ref("actor-1")
    SolidObjects.configuration.authorize_subscription = ->(**) { true }
    subscribe(
      token: SolidObjects::StreamToken.generate(reference, observables: []),
      components: JSON.generate(
        [
          component_token(
            reference,
            component_name: "summary",
            dependencies: %w[missing],
            revision: 0
          )
        ]
      )
    )
    reference.async(:update_missing)
    worker = SolidObjects::Worker.new
    worker.run_until_idle
    broadcast = SolidObjects::Broadcast.find_by!(observable_name: "missing")

    subscription.__send__(
      :receive_broadcast,
      SolidObjects::TurboStreamRenderer.observable(broadcast)
    )

    scalar_target = SolidObjects::DomIdentity.observable(reference, :missing)
    refute transmissions.any? { |transmission| transmission.include?(scalar_target) }
    assert_equal 1, component_refreshes(reference, :summary).length
  ensure
    worker&.stop
  end

  test "refreshes stale components from current state after reconnect" do
    reference = ChannelActor.ref("actor-1")
    reference.update_missing
    SolidObjects.configuration.authorize_subscription = ->(**) { true }

    subscribe(
      token: SolidObjects::StreamToken.generate(reference),
      components: JSON.generate(
        [
          component_token(
            reference,
            component_name: "summary",
            dependencies: %w[missing],
            revision: 0
          )
        ]
      )
    )

    refreshes = component_refreshes(reference, :summary)
    assert_equal 1, refreshes.length, transmissions.inspect
    refresh = refreshes.first
    assert_includes refresh, "revision=1"
    refute_includes refresh, "alice"
    refute_includes refresh, "bob"
  end

  test "ignores an older component invalidation after a newer one" do
    reference = ChannelActor.ref("actor-1")
    SolidObjects.configuration.authorize_subscription = ->(**) { true }
    subscribe(
      token: SolidObjects::StreamToken.generate(reference),
      components: JSON.generate(
        [
          component_token(
            reference,
            component_name: "summary",
            dependencies: %w[missing],
            revision: 0
          )
        ]
      )
    )
    2.times { reference.async(:update_missing) }
    worker = SolidObjects::Worker.new
    worker.run_until_idle
    broadcasts = SolidObjects::Broadcast
      .where(observable_name: "missing")
      .includes(:message)
      .sort_by { |broadcast| broadcast.message.sequence }

    broadcasts.reverse_each do |broadcast|
      subscription.__send__(
        :receive_broadcast,
        SolidObjects::TurboStreamRenderer.observable(broadcast)
      )
    end

    refreshes = component_refreshes(reference, :summary)
    assert_equal 1, refreshes.length
    assert_includes refreshes.first, "revision=2"
  ensure
    worker&.stop
  end

  test "rejects malformed component registrations" do
    reference = ChannelActor.ref("actor-1")
    SolidObjects.configuration.authorize_subscription = ->(**) { true }

    subscribe(
      token: SolidObjects::StreamToken.generate(reference),
      components: JSON.generate([ "malformed" ])
    )

    assert subscription.rejected?
    assert_no_streams
  end

  private

  def component_token(reference, component_name:, dependencies:, revision:)
    SolidObjects::ComponentToken.generate(
      reference:,
      component_name:,
      dependencies:,
      instance_id: 0,
      revision:,
      refresh_path: "/solid_objects/components"
    )
  end

  def component_refreshes(reference, component_name)
    target = SolidObjects::DomIdentity.component(reference, component_name)
    transmissions.select do |transmission|
      transmission.include?(%(target="#{target}")) &&
        transmission.include?("<turbo-frame")
    end
  end
end
