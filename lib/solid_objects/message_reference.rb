# rbs_inline: enabled

module SolidObjects
  class MessageReference
    class << self
      # @rbs (Message) -> MessageReference
      def from_message(message)
        new(
          id: message.id,
          request_id: message.request_id,
          actor_type: message.actor_type,
          actor_id: message.actor_id,
          sequence: message.sequence
        )
      end
    end

    # @rbs @id: Integer
    # @rbs @request_id: String
    # @rbs @actor_type: String
    # @rbs @actor_id: String
    # @rbs @sequence: Integer

    attr_reader :id, :request_id, :actor_type, :actor_id, :sequence

    # @rbs (id: Integer, request_id: String, actor_type: String, actor_id: String, sequence: Integer) -> void
    def initialize(id:, request_id:, actor_type:, actor_id:, sequence:)
      @id = id
      @request_id = request_id
      @actor_type = actor_type
      @actor_id = actor_id
      @sequence = sequence
      freeze
    end

    # @rbs () -> String
    def status
      Message.uncached { status_of(Message.find(id)) }
    end

    # @rbs () -> untyped
    def result
      Message.uncached { Message.find(id).result }
    end

    # @rbs () -> Outcome
    def outcome
      Message.uncached do
        message = Message.find(id)
        Outcome.new(
          status: status_of(message),
          result: Serialization.readonly_copy(message.result),
          error: ErrorRecord.from(message.error),
          rejection: RejectionRecord.from(message.rejection),
          attempts: message.attempt_count
        )
      end
    end

    # @rbs (?timeout: Numeric, ?authorization_context: untyped) -> untyped
    def wait(timeout: 5.seconds, authorization_context: nil)
      SolidObjects.client.wait(
        self,
        timeout:,
        authorization_context:
      )
    end

    private

    # @rbs (Message) -> String
    def status_of(message)
      return "rejected" if message.rejected?
      return "completed" if message.completed?
      return "dead" if message.dead?
      return "claimed" if message.claimed?
      return "ready" if message.ready?

      "unknown"
    end
  end
end
