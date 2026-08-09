# rbs_inline: enabled

require "action_cable"

module SolidObjects
  class ActorChannel < ActionCable::Channel::Base
    # @rbs () -> void
    def subscribed
      identity = StreamToken.verify(params.fetch("token"))
      actor_type = identity.fetch("actor_type")
      actor_id = identity.fetch("actor_id")
      SolidObjects.registry.fetch(actor_type)
      authorized = SolidObjects.configuration.authorize_subscription.call(
        actor_type:,
        actor_id:,
        authorization_context: connection
      )
      return reject unless authorized

      @reference = Reference.new(actor_type:, actor_id:)
      @scalar_observables = identity["observables"]
      @payload_names = identity["payloads"]
      validate_scalar_observables!
      validate_payload_names!
      @component_subscriptions = ComponentSubscriptions.parse(
        params["components"],
        reference:
      )
      stream_from StreamName.for(reference), coder: ActiveSupport::JSON do |stream|
        receive_broadcast(stream)
      end
      snapshot = ActorSnapshot.new(reference)
      scalar_observable_names(snapshot).each do |name|
        transmit TurboStreamRenderer.observable_value(
          reference,
          name,
          snapshot.observable_value(name)
        )
      end
      refresh_outdated_components(snapshot)
      transmit_state_payloads(snapshot)
    rescue KeyError,
      JSON::ParserError,
      InvalidStreamToken,
      InvalidComponentToken,
      UnknownActorType
      reject
    end

    private

    attr_reader :reference,
      :component_subscriptions,
      :scalar_observables,
      :payload_names

    # @rbs (String) -> void
    def receive_broadcast(stream)
      invalidation = TurboStreamRenderer.invalidation(stream)
      if !invalidation ||
          scalar_observables.nil? ||
          scalar_observables.include?(invalidation.fetch("observable_name"))
        transmit stream
      end
      return unless invalidation

      component_subscriptions
        .refreshes_for(invalidation)
        .each { |refresh| transmit refresh }
      transmit_state_payloads(ActorSnapshot.new(reference))
    end

    # @rbs (ActorSnapshot) -> void
    def transmit_state_payloads(snapshot)
      return if payload_names.nil? || payload_names.empty?
      return unless newer_payload_revision?(snapshot)

      payload_names.each do |name|
        payload = PayloadBroadcast.new(
          snapshot:,
          name:,
          authorization_context: connection
        ).call
        transmit TurboStreamRenderer.state_payload(payload)
      rescue Unauthorized
        next
      end
      @payload_revision = [ snapshot.instance_id, snapshot.revision ]
    end

    # @rbs (ActorSnapshot) -> bool
    def newer_payload_revision?(snapshot)
      current = @payload_revision
      return true unless current

      (current <=> [ snapshot.instance_id, snapshot.revision ]) == -1
    end

    # @rbs () -> void
    def validate_payload_names!
      return unless payload_names

      broadcasts = SolidObjects
        .registry
        .fetch(reference.actor_type)
        .definition
        .payload_broadcasts
      unknown = payload_names.find { |name| !broadcasts.key?(name.to_sym) }
      return unless unknown

      raise InvalidStreamToken, "unknown payload broadcast #{unknown.inspect}"
    end

    # @rbs (ActorSnapshot) -> void
    def refresh_outdated_components(snapshot)
      component_subscriptions
        .reconnect_refreshes(snapshot)
        .each { |refresh| transmit refresh }
    end

    # @rbs () -> void
    def validate_scalar_observables!
      return unless scalar_observables

      observables = SolidObjects
        .registry
        .fetch(reference.actor_type)
        .definition
        .observables
      unknown = scalar_observables.find do |name|
        !observables.key?(name.to_sym)
      end
      return unless unknown

      raise InvalidStreamToken, "unknown scalar observable #{unknown.inspect}"
    end

    # @rbs (ActorSnapshot) -> Array[String]
    def scalar_observable_names(snapshot)
      return scalar_observables if scalar_observables

      snapshot.actor_class.definition.observables.keys.map(&:to_s)
    end
  end
end
