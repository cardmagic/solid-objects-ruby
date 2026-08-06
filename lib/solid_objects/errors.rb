# rbs_inline: enabled

module SolidObjects
  class Error < StandardError
  end

  class UnsupportedDatabase < Error
  end

  class InvalidActor < Error
  end

  class UnknownActorType < Error
  end

  class UnknownMessage < Error
  end

  class InvalidPayload < Error
  end

  class PayloadTooLarge < InvalidPayload
  end

  class MailboxFull < Error
  end

  class IdempotencyConflict < Error
  end

  class Unauthorized < Error
  end

  class InvalidStreamToken < Error
  end

  class LostActivation < Error
  end

  class ActorDestroyed < LostActivation
  end

  class SyncTimeout < Error
  end

  class Rejected < Error
    # @rbs @code: String
    # @rbs @details: Hash[String, untyped]
    # @rbs @message_id: Integer?

    attr_reader :code, :details, :message_id

    # @rbs (code: String | Symbol, message: String, ?details: Hash[String | Symbol, untyped], ?message_id: Integer?) -> void
    def initialize(code:, message:, details: {}, message_id: nil)
      @code = code.to_s
      @details = Serialization.dump(details)
      @message_id = message_id
      super(message)
    end
  end

  class MessageFailed < Error
    # @rbs @message_id: Integer
    # @rbs @details: Hash[String, untyped]

    attr_reader :message_id, :details

    # @rbs (String, message_id: Integer, details: Hash[String, untyped]) -> void
    def initialize(message, message_id:, details:)
      @message_id = message_id
      @details = details
      super(message)
    end
  end

  class StateMigrationError < Error
  end

  class ActorCallCycle < Error
  end
end
