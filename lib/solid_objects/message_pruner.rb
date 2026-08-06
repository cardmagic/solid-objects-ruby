# rbs_inline: enabled

module SolidObjects
  class MessagePruner
    # @rbs @now: Time
    # @rbs @batch_size: Integer

    # @rbs (?now: Time, ?batch_size: Integer) -> void
    def initialize(
      now: SolidObjects.database_adapter.database_now,
      batch_size: SolidObjects.configuration.prune_batch_size
    )
      @now = now
      @batch_size = batch_size
    end

    # @rbs () -> Integer
    def preview
      policy_relations.sum(&:count)
    end

    # @rbs () -> Integer
    def prune
      policy_relations.sum { |relation| prune_relation(relation) }.tap do |count|
        SolidObjects.instrument(:"messages.pruned", count:)
      end
    end

    private

    attr_reader :now, :batch_size

    # @rbs () -> Array[ActiveRecord::Relation[Message]]
    def policy_relations
      overrides = retention_overrides
      relations = overrides.map do |actor_type, retention|
        prunable.where(actor_type:, completed_at: ...retention_cutoff(retention))
      end
      default_relation = prunable.where(completed_at: ...retention_cutoff(default_retention))
      default_relation = default_relation.where.not(actor_type: overrides.keys) if overrides.any?
      relations << default_relation
    end

    # @rbs () -> ActiveRecord::Relation[Message]
    def prunable
      Message
        .where.not(id: ReadyMessage.select(:message_id))
        .where.not(id: ClaimedMessage.select(:message_id))
        .where.not(id: DeadLetter.select(:message_id))
        .where.not(
          id: DeadLetter
            .where.not(retried_message_id: nil)
            .select(:retried_message_id)
        )
        .where.not(
          id: Effect
            .where.not(status: "completed")
            .select(:message_id)
        )
        .where.not(
          id: Broadcast
            .where.not(status: "delivered")
            .select(:message_id)
        )
    end

    # @rbs (ActiveRecord::Relation[Message]) -> Integer
    def prune_relation(relation)
      deleted = 0

      loop do
        message_ids = relation.limit(batch_size).pluck(:id)
        break if message_ids.empty?

        deleted += Message.where(id: message_ids).delete_all
      end

      deleted
    end

    # @rbs () -> Numeric
    def default_retention
      SolidObjects.configuration.message_retention
    end

    # @rbs () -> Hash[String, Numeric]
    def retention_overrides
      SolidObjects.configuration.message_retention_by_actor_type
        .to_h { |actor_type, retention| [ actor_type.to_s, retention ] }
    end

    # @rbs (Numeric) -> Time
    def retention_cutoff(retention)
      now - retention
    end
  end
end
