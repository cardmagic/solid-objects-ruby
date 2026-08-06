# rbs_inline: enabled

module SolidObjects
  class Error < StandardError
  end

  class NonRetryableError < Error
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

  class DatabaseDeadlineExceeded < Error
  end

  class SyncEnqueueTimeout < Error
    # @rbs @timeout: Numeric
    # @rbs @actor_type: String
    # @rbs @actor_id: String
    # @rbs @message_name: String

    attr_reader :timeout, :actor_type, :actor_id, :message_name

    # @rbs (timeout: Numeric, actor_type: String, actor_id: String, message_name: String) -> void
    def initialize(timeout:, actor_type:, actor_id:, message_name:)
      @timeout = timeout
      @actor_type = actor_type
      @actor_id = actor_id
      @message_name = message_name
      super(
        "actor invocation could not be durably enqueued within #{timeout} seconds for " \
          "#{actor_type}(#{actor_id.inspect}).#{message_name}"
      )
    end
  end

  class SyncTimeout < Error
    # @rbs @timeout: Numeric
    # @rbs @actor_type: String
    # @rbs @actor_id: String
    # @rbs @message_name: String
    # @rbs @message_id: Integer
    # @rbs @request_id: String
    # @rbs @sequence: Integer
    # @rbs @status: String
    # @rbs @waiting_on: String
    # @rbs @activation: Hash[String, untyped]
    # @rbs @blocker: Hash[String, untyped]?

    attr_reader :timeout,
      :actor_type,
      :actor_id,
      :message_name,
      :message_id,
      :request_id,
      :sequence,
      :status,
      :waiting_on,
      :activation,
      :blocker

    # @rbs (timeout: Numeric, actor_type: String, actor_id: String, message_name: String, message_id: Integer, request_id: String, sequence: Integer, status: String, waiting_on: String, activation: Hash[String, untyped], blocker: Hash[String, untyped]?) -> void
    def initialize(
      timeout:,
      actor_type:,
      actor_id:,
      message_name:,
      message_id:,
      request_id:,
      sequence:,
      status:,
      waiting_on:,
      activation:,
      blocker:
    )
      @timeout = timeout
      @actor_type = actor_type
      @actor_id = actor_id
      @message_name = message_name
      @message_id = message_id
      @request_id = request_id
      @sequence = sequence
      @status = status
      @waiting_on = waiting_on
      @activation = Serialization.readonly_copy(activation)
      @blocker = Serialization.readonly_copy(blocker)
      super(
        "actor invocation timed out after #{timeout} seconds for " \
          "#{actor_type}(#{actor_id.inspect}).#{message_name} " \
          "message_id=#{message_id} sequence=#{sequence} status=#{status} waiting_on=#{waiting_on}"
      )
    end

    # @rbs () -> MessageReference
    def message_reference
      MessageReference.new(
        id: message_id,
        request_id:,
        actor_type:,
        actor_id:,
        sequence:
      )
    end
  end

  class SyncInsideTransaction < Error
    # @rbs @actor_type: String
    # @rbs @actor_id: String
    # @rbs @message_name: String

    attr_reader :actor_type, :actor_id, :message_name

    # @rbs (actor_type: String, actor_id: String, message_name: String) -> void
    def initialize(actor_type:, actor_id:, message_name:)
      @actor_type = actor_type
      @actor_id = actor_id
      @message_name = message_name
      super(
        "cannot synchronously invoke #{actor_type}(#{actor_id.inspect}).#{message_name} " \
          "inside an open database transaction; call it before the transaction or enqueue it with async"
      )
    end
  end

  class ApplicationWriteForbidden < NonRetryableError
    # @rbs @actor_type: String
    # @rbs @actor_id: String
    # @rbs @message_name: String

    attr_reader :actor_type, :actor_id, :message_name

    # @rbs (actor_type: String, actor_id: String, message_name: String) -> void
    def initialize(actor_type:, actor_id:, message_name:)
      @actor_type = actor_type
      @actor_id = actor_id
      @message_name = message_name
      super(
        "#{actor_type}(#{actor_id.inspect}).#{message_name} attempted an Active Record write; " \
          "mutate actor state, stage a commit action, or emit a durable effect instead"
      )
    end
  end

  class CommitActionUnavailable < NonRetryableError
    # @rbs (actor_type: String, actor_id: String, message_name: String) -> void
    def initialize(actor_type:, actor_id:, message_name:)
      super(
        "#{actor_type}(#{actor_id.inspect}).#{message_name} staged a commit action, " \
          "but Solid Objects uses a separate database from Active Record"
      )
    end
  end

  class UnknownCommitAction < NonRetryableError
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
