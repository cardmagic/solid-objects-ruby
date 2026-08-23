# rbs_inline: enabled

require "action_controller/api"

module SolidObjects
  class TransmissionsController < ActionController::API
    # @rbs () -> void
    def create
      envelope = JSON.parse(request.body.read)
      return head :forbidden unless authorized_transmission?(envelope)

      Transmission.receive(
        envelope,
        resolve_actor_type: SolidObjects.configuration.transmission_actor_type_resolver
      )
      head :ok
    rescue JSON::ParserError, InvalidTransmission, UnknownActorType, UnknownMessage,
      PayloadTooLarge, IdempotencyConflict
      head :unprocessable_entity
    end

    private

    # @rbs (untyped) -> bool
    def authorized_transmission?(envelope)
      SolidObjects.configuration.authorize_transmission.call(
        envelope:,
        authorization_context: self
      )
    end
  end
end
