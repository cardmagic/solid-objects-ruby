# frozen_string_literal: true

require "database_test_helper"
require "action_cable/test_helper"
require "action_cable/channel/test_case"
require "action_view/test_case"
require "action_view/testing/resolvers"
require "cgi/escape"
require_relative "../../app/helpers/solid_objects/actor_helper"

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

  class CapturingActorChannel < SolidObjects::ActorChannel
    attr_reader :stream_callback, :stream_coder

    def stream_from(_broadcasting, callback = nil, coder: nil, &block)
      @stream_callback = callback || block
      @stream_coder = coder
    end
  end

  setup do
    SolidObjects.reset!
    ChannelActor.ensure_registered!
    SolidObjects.configuration.stream_signing_secret = "test-stream-signing-secret"
    SolidObjects.configuration.authorize_message = ->(**) { true }
    SolidObjects.configuration.authorize_query = ->(**) { true }
    SolidObjects.configuration.component_path_resolver = lambda do |view_context:|
      "/solid_objects/components"
    end
    ActionCable.server.config.logger = Logger.new(nil)
  end

  test "loads the actor channel with the gem" do
    assert_equal SolidObjects::ActorChannel,
      "SolidObjects::ActorChannel".safe_constantize
  end

  test "subscribes to scalar updates through rendered Turbo data" do
    reference = ChannelActor.ref("actor-1")
    SolidObjects.configuration.authorize_subscription = ->(**) { true }
    parameters = rendered_subscription_parameters(reference) do |actor|
      actor.missing
    end

    assert_equal "SolidObjects::ActorChannel", parameters.fetch(:channel)
    assert parameters.key?(:token)
    refute parameters.key?(:components)

    subscribe(**parameters)

    assert subscription.confirmed?
    assert_has_stream SolidObjects::StreamName.for(reference)

    reference.async(:update_missing)
    worker = SolidObjects::Worker.new
    worker.run_until_idle
    broadcast = SolidObjects::Broadcast.find_by!(observable_name: "missing")
    subscription.__send__(
      :receive_broadcast,
      SolidObjects::TurboStreamRenderer.observable(broadcast)
    )

    target = SolidObjects::DomIdentity.observable(reference, :missing)
    updates = transmissions.select { |transmission| transmission.include?(target) }
    assert_equal 2, updates.length
    assert_includes updates.last, ">1</span>"
  ensure
    worker&.stop
  end

  test "subscribes to component updates through rendered Turbo data" do
    reference = ChannelActor.ref("actor-1")
    SolidObjects.configuration.authorize_subscription = ->(**) { true }
    parameters = rendered_subscription_parameters(reference) do |actor|
      actor.component(:summary, observes: :missing)
    end

    assert_equal "SolidObjects::ActorChannel", parameters.fetch(:channel)
    assert parameters.key?(:token)
    assert parameters.key?(:components)

    subscribe(**parameters)

    assert subscription.confirmed?
    assert_has_stream SolidObjects::StreamName.for(reference)

    reference.async(:update_missing)
    worker = SolidObjects::Worker.new
    worker.run_until_idle
    broadcast = SolidObjects::Broadcast.find_by!(observable_name: "missing")
    subscription.__send__(
      :receive_broadcast,
      SolidObjects::TurboStreamRenderer.observable(broadcast)
    )

    assert_equal 1, component_refreshes(reference, :summary).length
  ensure
    worker&.stop
  end

  test "decodes Action Cable broadcasts before reactive processing" do
    reference = ChannelActor.ref("actor-1")
    SolidObjects.configuration.authorize_subscription = ->(**) { true }
    connection = ActionCable::Channel::ConnectionStub.new
    channel = CapturingActorChannel.new(
      connection,
      "actor-channel",
      {
        token: SolidObjects::StreamToken.generate(
          reference,
          observables: %w[missing]
        ),
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
      }.with_indifferent_access
    )
    channel.subscribe_to_channel

    assert_equal ActiveSupport::JSON, channel.stream_coder
    connection.transmissions.clear

    reference.async(:update_missing)
    worker = SolidObjects::Worker.new
    worker.run_until_idle
    broadcast = SolidObjects::Broadcast.find_by!(observable_name: "missing")
    SolidObjects::ActionCableBroadcastAdapter.new.call(broadcast)
    stream_name = SolidObjects::StreamName.for(reference)
    encoded_stream = ActionCable.server.pubsub.broadcasts(stream_name).sole
    handler = channel.__send__(
      :stream_handler,
      stream_name,
      channel.stream_callback,
      coder: channel.stream_coder
    )

    handler.call(encoded_stream)

    channel_transmissions = connection.transmissions.filter_map do |transmission|
      transmission["message"]
    end
    scalar_target = SolidObjects::DomIdentity.observable(reference, :missing)
    scalar_update = channel_transmissions.find do |transmission|
      transmission.include?(scalar_target) &&
        transmission.include?(">1</span>")
    end
    assert scalar_update
    assert_equal 1,
      component_refreshes(
        reference,
        :summary,
        messages: channel_transmissions
      ).length
    refute channel_transmissions.any? { |transmission| transmission.start_with?("\"") }
  ensure
    worker&.stop
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

  test "refreshes repeatable keyed components independently" do
    reference = ChannelActor.ref("actor-1")
    SolidObjects.configuration.authorize_subscription = ->(**) { true }
    subscribe(
      token: SolidObjects::StreamToken.generate(reference),
      components: JSON.generate(
        %w[alice bob].map do |player_id|
          component_token(
            reference,
            component_name: "player",
            component_key: player_id,
            dependencies: %w[status],
            locals: { player_id: },
            revision: 0
          )
        end
      )
    )
    reference.async(:update_all)
    worker = SolidObjects::Worker.new
    worker.run_until_idle
    broadcast = SolidObjects::Broadcast.find_by!(observable_name: "status")

    subscription.__send__(
      :receive_broadcast,
      SolidObjects::TurboStreamRenderer.observable(broadcast)
    )

    assert_equal 1, component_refreshes(reference, :player, key: "alice").length
    assert_equal 1, component_refreshes(reference, :player, key: "bob").length
  ensure
    worker&.stop
  end

  test "rejects duplicate keyed component registrations" do
    reference = ChannelActor.ref("actor-1")
    SolidObjects.configuration.authorize_subscription = ->(**) { true }
    token = component_token(
      reference,
      component_name: "player",
      component_key: "alice",
      dependencies: %w[status],
      revision: 0
    )

    subscribe(
      token: SolidObjects::StreamToken.generate(reference),
      components: JSON.generate([ token, token ])
    )

    assert subscription.rejected?
    assert_no_streams
  end

  test "routes invalidations by each keyed component dependency" do
    reference = ChannelActor.ref("actor-1")
    SolidObjects.configuration.authorize_subscription = ->(**) { true }
    subscribe(
      token: SolidObjects::StreamToken.generate(reference),
      components: JSON.generate(
        [
          component_token(
            reference,
            component_name: "player",
            component_key: "alice",
            dependencies: %w[status],
            revision: 0
          ),
          component_token(
            reference,
            component_name: "player",
            component_key: "bob",
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

    assert_empty component_refreshes(reference, :player, key: "alice")
    assert_equal 1, component_refreshes(reference, :player, key: "bob").length
  ensure
    worker&.stop
  end

  test "transmits a morph refresh through the browser refresh element" do
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
            refresh_method: "morph",
            revision: 0
          )
        ]
      )
    )
    reference.async(:update_all)
    worker = SolidObjects::Worker.new
    worker.run_until_idle
    broadcast = SolidObjects::Broadcast.find_by!(observable_name: "status")

    subscription.__send__(
      :receive_broadcast,
      SolidObjects::TurboStreamRenderer.observable(broadcast)
    )

    refresh = transmissions.find do |transmission|
      transmission.include?("<solid-objects-refresh")
    end
    assert refresh
    assert_includes refresh, %(action="append")
    assert_includes refresh, %(data-refresh-method="morph")
    assert_includes refresh, %(revision=1)
  ensure
    worker&.stop
  end

  private

  def rendered_subscription_parameters(reference, &block)
    html = actor_view.solid_object(reference, &block)
    source = html.match(/<turbo-cable-stream-source (?<attributes>[^>]*)>/)
    attributes = source[:attributes]
      .scan(/([a-z-]+)="([^"]*)"/)
      .to_h
    data = attributes
      .select { |name, _value| name.start_with?("data-") }
      .to_h do |name, value|
        [ name.delete_prefix("data-").tr("-", "_").to_sym, CGI.unescapeHTML(value) ]
      end

    {
      channel: attributes.fetch("channel"),
      **data
    }
  end

  def actor_view
    resolver = ActionView::FixtureResolver.new(
      "actors/actor_channel_test/channel_actor/_summary.html.erb" =>
        "<p><%= actor.missing %></p>"
    )
    view = ActionView::Base
      .with_empty_template_cache
      .with_view_paths([ resolver ])
    view.extend(SolidObjects::ActorHelper)
    view
  end

  def component_token(
    reference,
    component_name:,
    dependencies:,
    revision:,
    component_key: nil,
    locals: {},
    refresh_method: "replace"
  )
    SolidObjects::ComponentToken.generate(
      reference:,
      component_name:,
      component_key:,
      dependencies:,
      locals:,
      refresh_method:,
      instance_id: 0,
      revision:,
      refresh_path: "/solid_objects/components"
    )
  end

  def component_refreshes(
    reference,
    component_name,
    key: nil,
    messages: transmissions
  )
    target = SolidObjects::DomIdentity.component(
      reference,
      component_name,
      key:
    )
    messages.select do |transmission|
      transmission.include?(%(target="#{target}")) &&
        transmission.include?("<turbo-frame")
    end
  end
end
