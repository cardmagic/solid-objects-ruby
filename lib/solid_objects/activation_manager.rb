# rbs_inline: enabled

module SolidObjects
  class ActivationManager
    # @rbs @owner_id: String
    # @rbs @database_adapter: DatabaseAdapter

    # @rbs (owner_id: String, ?database_adapter: DatabaseAdapter) -> void
    def initialize(owner_id:, database_adapter: SolidObjects.database_adapter)
      @owner_id = owner_id
      @database_adapter = database_adapter
    end

    # @rbs () -> Activation?
    def claim_next
      claim_from(candidate_instance_ids(database_adapter.database_now))
    end

    # @rbs (instance_id: Integer) -> Activation?
    def claim(instance_id:)
      claim_from([ instance_id ])
    end

    private

    attr_reader :owner_id, :database_adapter

    # @rbs (Array[Integer]) -> Activation?
    def claim_from(instance_ids)
      lease = database_adapter.transaction do
        now = database_adapter.database_now
        claimed_lease = nil
        instance_ids.each do |instance_id|
          instance = database_adapter.lock_candidates(
            Instance.where(id: instance_id)
          ).first
          next unless instance
          next unless claimable?(instance, now)

          claimed_lease = Lease.claim(
            instance:,
            owner_id:,
            activation_token: SecureRandom.uuid,
            now:,
            database_adapter:
          )
          break if claimed_lease
        end
        claimed_lease
      end
      return unless lease

      SolidObjects.instrument(
        :"activation.claimed",
        instance_id: lease.instance_id,
        owner_id:,
        generation: lease.generation
      )
      Activation.new(lease:)
    rescue
      lease&.release
      raise
    end

    # @rbs (Time) -> Array[Integer]
    def candidate_instance_ids(now)
      (ready_instance_ids(now) + claimed_instance_ids(now)).uniq
    end

    # @rbs (Time) -> Array[Integer]
    def ready_instance_ids(now)
      ReadyMessage
        .joins(:instance)
        .where(available_at: ..now)
        .where("#{Instance.table_name}.paused_at IS NULL")
        .where(available_lease_sql, now)
        .group(:instance_id)
        .order(
          Arel.sql("MIN(available_at)"),
          Arel.sql("MIN(#{ReadyMessage.table_name}.id)")
        )
        .limit(SolidObjects.configuration.claim_scan_limit)
        .pluck(:instance_id)
    end

    # @rbs (Time) -> Array[Integer]
    def claimed_instance_ids(now)
      ClaimedMessage
        .joins(:instance)
        .where("#{Instance.table_name}.paused_at IS NULL")
        .where(available_lease_sql, now)
        .group(:instance_id)
        .order(
          Arel.sql("MIN(claimed_at)"),
          Arel.sql("MIN(#{ClaimedMessage.table_name}.id)")
        )
        .limit(SolidObjects.configuration.claim_scan_limit)
        .pluck(:instance_id)
    end

    # @rbs (Instance, Time) -> bool
    def claimable?(instance, now)
      return false if instance.paused_at
      return true unless instance.activation_owner_id
      return true unless instance.activation_expires_at

      instance.activation_expires_at <= now
    end

    # @rbs () -> String
    def available_lease_sql
      table_name = Instance.table_name
      "#{table_name}.activation_owner_id IS NULL OR " \
        "#{table_name}.activation_expires_at IS NULL OR " \
        "#{table_name}.activation_expires_at <= ?"
    end
  end
end
