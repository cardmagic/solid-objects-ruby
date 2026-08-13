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
          reference:,
          name:,
          value: snapshot.observable_value(name)
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
      revision_only = invalidation &&
        invalidation.fetch("observable_name") == PayloadBroadcast::REVISION_OBSERVABLE
      if !revision_only &&
          (!invalidation ||
            scalar_observables.nil? ||
            scalar_observables.include?(invalidation.fetch("observable_name")))
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

      # The watermark records what the subscriber has, so a revision with a
      # failed payload must not advance it: dedup would skip every later
      # attempt at that revision and the actor may not mutate again for a long
      # time. Every name is still attempted before the decision is made.
      attempts = payload_names.map { |name| transmit_state_payload(snapshot, name) }
      return if attempts.any?(false)

      @payload_revision = [ snapshot.instance_id, snapshot.revision ]
    end

    # A payload is one subscriber's view of one name. Letting it raise through
    # here would reject the subscription or abandon the rest of a broadcast, so
    # a failure is confined to the payload that caused it and reported. The
    # exception message is deliberately not instrumented: a payload block reads
    # actor state, so its message is the one place subscriber state could leak
    # into logs.
    #
    # Returns whether this revision was settled for the name. An unauthorized
    # payload is settled: the decision is stable, so retrying it would only
    # re-deliver its authorized siblings.
    # @rbs (ActorSnapshot, String) -> bool
    def transmit_state_payload(snapshot, name)
      payload = PayloadBroadcast.new(
        snapshot:,
        name:,
        authorization_context: payload_authorization_context(name)
      ).call
      transmit TurboStreamRenderer.state_payload(payload)
      true
    rescue Unauthorized
      true
    rescue => error
      SolidObjects.instrument(
        :payload_broadcast_failed,
        actor_type: reference.actor_type,
        actor_id: reference.actor_id,
        payload_name: name,
        error_class: error.class.name
      )
      false
    end

    # Resolves the Cable connection to whatever the application uses as an
    # authorization subject, so a payload block and `authorize_query` see the
    # same object a controller render would pass.
    # @rbs (String) -> untyped
    def payload_authorization_context(name)
      callable = SolidObjects.configuration.payload_authorization_context
      return callable.call(connection:) unless CallableKeywords.accepts?(callable, :payload_name)

      callable.call(connection:, payload_name: name)
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

      definition = SolidObjects
        .registry
        .fetch(reference.actor_type)
        .definition
      unknown = scalar_observables.find do |name|
        !definition.observables.key?(name.to_sym) ||
          !definition.broadcasts_observable_value?(name)
      end
      return unless unknown

      raise InvalidStreamToken, "unknown scalar observable #{unknown.inspect}"
    end

    # @rbs (ActorSnapshot) -> Array[String]
    def scalar_observable_names(snapshot)
      return scalar_observables if scalar_observables

      definition = snapshot.actor_class.definition
      definition.observables.keys.filter_map do |name|
        name.to_s if definition.broadcasts_observable_value?(name)
      end
    end
  end
end
