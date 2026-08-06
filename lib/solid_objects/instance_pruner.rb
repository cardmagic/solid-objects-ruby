# rbs_inline: enabled

module SolidObjects
  class InstancePruner
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
        SolidObjects.instrument(:"instances.pruned", count:)
      end
    end

    private

    attr_reader :now, :batch_size

    # @rbs () -> Array[ActiveRecord::Relation[Instance]]
    def policy_relations
      SolidObjects.configuration.instance_retention_by_actor_type.map do |actor_type, retention|
        prunable
          .where(actor_type: actor_type.to_s)
          .where("COALESCE(last_used_at, created_at) < ?", now - retention)
      end
    end

    # @rbs () -> ActiveRecord::Relation[Instance]
    def prunable
      Instance
        .where(activation_owner_id: nil, paused_at: nil)
        .where.not(id: ReadyMessage.select(:instance_id))
        .where.not(id: ClaimedMessage.select(:instance_id))
        .where.not(
          id: Reminder.where(status: "scheduled").select(:instance_id)
        )
        .where.not(
          id: Effect.where.not(status: "completed").select(:instance_id)
        )
        .where.not(
          id: Broadcast.where.not(status: "delivered").select(:instance_id)
        )
        .where.not(id: DeadLetter.select(:instance_id))
    end

    # @rbs (ActiveRecord::Relation[Instance]) -> Integer
    def prune_relation(relation)
      deleted = 0

      loop do
        instance_ids = relation.limit(batch_size).pluck(:id)
        break if instance_ids.empty?

        instance_ids.each do |instance_id|
          deleted += prune_instance(instance_id, relation)
        end
      end

      deleted
    end

    # @rbs (Integer, ActiveRecord::Relation[Instance]) -> Integer
    def prune_instance(instance_id, relation)
      expired_actor = SolidObjects.database_adapter.transaction do
        instance = Instance.lock.find_by(id: instance_id)
        next unless instance
        next unless relation.where(id: instance_id).exists?

        identity = {
          instance_id:,
          actor_type: instance.actor_type,
          actor_id: instance.actor_id
        }
        instance.delete
        identity
      end
      return 0 unless expired_actor

      SolidObjects.instrument(:"actor.expired", **expired_actor)
      1
    end
  end
end
