# rbs_inline: enabled

module SolidObjects
  class Instance < Record
    self.table_name = SolidObjects.table_name(:instances)

    belongs_to :activation_owner,
      class_name: "SolidObjects::Process",
      optional: true,
      inverse_of: :instances
    has_many :messages,
      class_name: "SolidObjects::Message",
      inverse_of: :instance,
      dependent: :destroy
    has_many :ready_messages,
      class_name: "SolidObjects::ReadyMessage",
      inverse_of: :instance,
      dependent: :destroy
    has_many :claimed_messages,
      class_name: "SolidObjects::ClaimedMessage",
      inverse_of: :instance,
      dependent: :destroy

    before_validation :supply_defaults

    validates :actor_type, :actor_id, presence: true, length: { maximum: 191 }

    class << self
      # @rbs (?actor_type: String?) -> ActiveRecord::Relation[Instance]
      def active(actor_type: nil)
        relation = where(paused_at: nil)
        actor_type ? relation.where(actor_type:) : relation
      end

      # @rbs (quiet_for: Numeric, ?now: Time) -> ActiveRecord::Relation[Instance]
      def without_pending_work(quiet_for:, now: SolidObjects.database_adapter.database_now)
        cutoff = now - quiet_for
        where("COALESCE(last_used_at, created_at) <= ?", cutoff)
          .where.not(id: ReadyMessage.select(:instance_id))
          .where.not(id: ClaimedMessage.select(:instance_id))
          .where.not(
            id: Reminder.where(status: "scheduled").select(:instance_id)
          )
      end

      # @rbs (actor_type: String, owner: ActiveRecord::Relation[untyped] | Class) -> ActiveRecord::Relation[Instance]
      def orphaned(actor_type:, owner:)
        owner_relation = owner.is_a?(ActiveRecord::Relation) ? owner : owner.all
        owner_class = owner_relation.klass
        owner_table = owner_class.arel_table
        owner_primary_key = owner_table[owner_class.primary_key]
        cast_type = Arel::Nodes::SqlLiteral.new(owner_id_cast_type)
        cast_id = Arel::Nodes::NamedFunction.new(
          "CAST",
          [ Arel::Nodes::As.new(owner_primary_key, cast_type) ]
        )
        owner_ids = owner_relation
          .except(:select)
          .select(collated(cast_id))

        where(actor_type:).where.not(actor_id: owner_ids)
      end

      # @rbs (actor_type: String, actor_ids: Array[String]) -> Hash[String, Hash[String, untyped]]
      def states_for(actor_type:, actor_ids:)
        where(actor_type:, actor_id: actor_ids)
          .pluck(:actor_id, :state)
          .to_h
      end

      private

      # A cast result carries the connection collation, not the column's, and
      # MySQL refuses to compare two collations. Which collation a connection
      # uses is a property of the client rather than the schema: mysql2
      # negotiates the database default while Trilogy negotiates
      # utf8mb4_general_ci, so the comparison is pinned to the column's own.
      # @rbs (untyped) -> untyped
      def collated(node)
        collation = owner_id_collation
        return node unless collation

        Arel::Nodes::InfixOperation.new(
          "COLLATE",
          node,
          Arel::Nodes::SqlLiteral.new(collation)
        )
      end

      # @rbs () -> String?
      def owner_id_collation
        return nil unless DatabaseAdapter.family(connection) == :mysql

        collation = columns_hash["actor_id"]&.collation
        return nil unless collation&.match?(/\A[a-zA-Z0-9_]+\z/)

        collation
      end

      # @rbs () -> String
      def owner_id_cast_type
        case DatabaseAdapter.family(connection)
        when :mysql
          "CHAR"
        when :postgresql
          "VARCHAR"
        else
          "TEXT"
        end
      end
    end

    private

    # @rbs () -> void
    def supply_defaults
      self.state ||= {}
    end
  end
end
