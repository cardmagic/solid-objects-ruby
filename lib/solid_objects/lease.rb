# rbs_inline: enabled

module SolidObjects
  class Lease
    class << self
      # @rbs (instance: Instance, owner_id: String, now: Time, ?duration: Numeric, database_adapter: DatabaseAdapter) -> Lease?
      def claim(
        instance:,
        owner_id:,
        now:,
        database_adapter:, duration: SolidObjects.configuration.lease_duration
      )
        return if held_by_another_live_owner?(instance, owner_id, now)

        generation = instance.activation_generation + 1
        expires_at = now + duration
        instance.update!(
          activation_owner_id: owner_id,
          activation_expires_at: expires_at,
          activation_generation: generation,
          activated_at: now,
          last_claimed_at: now
        )
        new(
          instance_id: instance.id,
          owner_id:,
          generation:,
          expires_at:,
          database_adapter:
        )
      end

      # @rbs (instance_id: Integer, owner_id: String, ?duration: Numeric, ?database_adapter: DatabaseAdapter) -> Lease?
      def acquire(
        instance_id:,
        owner_id:,
        duration: SolidObjects.configuration.lease_duration,
        database_adapter: SolidObjects.database_adapter
      )
        lease = database_adapter.transaction do
          instance = Instance.lock.find(instance_id)
          now = database_adapter.database_now
          claim(instance:, owner_id:, now:, duration:, database_adapter:)
        end

        if lease
          SolidObjects.instrument(
            :"activation.claimed",
            instance_id:,
            owner_id:,
            generation: lease.generation
          )
        end

        lease
      end

      private

      # @rbs (Instance, String, Time) -> bool
      def held_by_another_live_owner?(instance, owner_id, now)
        instance.activation_owner_id.present? &&
          instance.activation_owner_id != owner_id &&
          instance.activation_expires_at.present? &&
          instance.activation_expires_at > now
      end
    end

    # @rbs @instance_id: Integer
    # @rbs @owner_id: String
    # @rbs @generation: Integer
    # @rbs @expires_at: Time
    # @rbs @database_adapter: DatabaseAdapter

    attr_reader :instance_id, :owner_id, :generation, :expires_at

    # @rbs (instance_id: Integer, owner_id: String, generation: Integer, expires_at: Time, database_adapter: DatabaseAdapter) -> void
    def initialize(instance_id:, owner_id:, generation:, expires_at:, database_adapter:)
      @instance_id = instance_id
      @owner_id = owner_id
      @generation = generation
      @expires_at = expires_at
      @database_adapter = database_adapter
    end

    # @rbs (?duration: Numeric) -> Lease
    def renew(duration: SolidObjects.configuration.lease_duration)
      renewed_lease = database_adapter.transaction do
        instance = locked_owned_instance!
        now = database_adapter.database_now
        verify_unexpired!(instance, now)
        renewed_expiration = now + duration
        instance.update!(activation_expires_at: renewed_expiration)

        self.class.new(
          instance_id:,
          owner_id:,
          generation:,
          expires_at: renewed_expiration,
          database_adapter:
        )
      end
      SolidObjects.instrument(
        :"activation.renewed",
        instance_id:,
        owner_id:,
        generation:,
        expires_at: renewed_lease.expires_at
      )
      renewed_lease
    end

    # @rbs () -> bool
    def release
      released = database_adapter.transaction do
        instance = Instance.lock.find(instance_id)
        next false unless owned_generation?(instance)

        instance.update!(activation_owner_id: nil, activation_expires_at: nil)
        true
      end

      if released
        SolidObjects.instrument(
          :"activation.released",
          instance_id:,
          owner_id:,
          generation:
        )
      end

      released
    end

    # @rbs () { (Instance) -> untyped } -> untyped
    def fenced_transaction
      database_adapter.transaction do
        instance = locked_owned_instance!
        verify_unexpired!(instance, database_adapter.database_now)
        yield instance
      end
    end

    private

    attr_reader :database_adapter

    # @rbs () -> Instance
    def locked_owned_instance!
      Instance.lock.find(instance_id).tap do |instance|
        raise LostActivation, "activation owner or generation changed" unless owned_generation?(instance)
      end
    end

    # @rbs (Instance) -> bool
    def owned_generation?(instance)
      instance.activation_owner_id == owner_id &&
        instance.activation_generation == generation
    end

    # @rbs (Instance, Time) -> void
    def verify_unexpired!(instance, now)
      return if instance.activation_expires_at && instance.activation_expires_at > now

      raise LostActivation, "activation lease expired"
    end
  end
end
