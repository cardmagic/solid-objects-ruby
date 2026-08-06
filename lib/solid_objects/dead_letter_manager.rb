# rbs_inline: enabled

module SolidObjects
  class DeadLetterManager
    # @rbs (?authorization_context: untyped) -> ActiveRecord::Relation[DeadLetter]
    def all(authorization_context: nil)
      authorize!(:inspect, authorization_context:)
      DeadLetter.order(last_failed_at: :desc, id: :desc)
    end

    # @rbs (Integer, ?authorization_context: untyped) -> MessageReference
    def retry(dead_letter_id, authorization_context: nil)
      authorize!(:retry, authorization_context:, dead_letter_id:)
      dead_letter = DeadLetter.find(dead_letter_id)
      return MessageReference.from_message(Message.find(dead_letter.retried_message_id)) if dead_letter.retried_message_id

      original_message = dead_letter.message
      message_reference = Mailbox.new.enqueue(
        Reference.new(
          actor_type: dead_letter.actor_type,
          actor_id: dead_letter.actor_id
        ),
        dead_letter.message_name,
        dead_letter.arguments,
        kind: original_message.message_kind,
        idempotency_key: "dead-letter:#{dead_letter.id}"
      )
      dead_letter.update!(retried_message_id: message_reference.id)
      message_reference
    end

    private

    # @rbs (Symbol, authorization_context: untyped, ?dead_letter_id: Integer?) -> void
    def authorize!(action, authorization_context:, dead_letter_id: nil)
      authorized = SolidObjects.configuration.authorize_administration.call(
        action: action.to_s,
        resource: "dead_letters",
        resource_id: dead_letter_id,
        authorization_context:
      )
      return if authorized

      raise Unauthorized, "actor administration is not authorized"
    end
  end
end
