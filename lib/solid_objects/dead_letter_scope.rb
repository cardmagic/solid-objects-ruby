# rbs_inline: enabled

module SolidObjects
  class DeadLetterScope
    DEAD = "dead"
    PENDING = "pending"

    # @rbs @model: untyped
    # @rbs @resource: String
    # @rbs @identifier: Symbol

    attr_reader :resource, :kind

    # @rbs (model: untyped, resource: String, identifier: Symbol, kind: String) -> void
    def initialize(model:, resource:, identifier:, kind:)
      @model = model
      @resource = resource
      @identifier = identifier
      @kind = kind
    end

    # @rbs (String) -> DeadLetterScope
    def self.for_kind(kind)
      return SolidObjects.dead_letters.effects if kind == "effect"
      return SolidObjects.dead_letters.broadcasts if kind == "broadcast"

      raise ArgumentError, "unknown dead letter kind #{kind.inspect}"
    end

    # @rbs (?authorization_context: untyped) -> ActiveRecord::Relation[untyped]
    def all(authorization_context: nil)
      authorize!(:inspect, authorization_context:)
      dead.order(updated_at: :desc, id: :desc)
    end

    # @rbs (String, ?authorization_context: untyped) -> untyped
    def retry(identifier_value, authorization_context: nil)
      authorize!(:retry, authorization_context:, resource_id: identifier_value)
      row = model.find_by!(identifier => identifier_value)
      AdministrationAudit.record(
        action: "dead_letter.retry",
        kind: kind,
        subject_id: identifier_value,
        actor: AdministrationAudit.identity(authorization_context)
      )
      return row unless row.status == DEAD

      revive(row)
      row
    end

    # @rbs (?actor_type: String?, ?failed_after: untyped, ?limit: Integer?, ?authorization_context: untyped) -> RedriveTask
    def redrive(actor_type: nil, failed_after: nil, limit: nil, authorization_context: nil)
      SolidObjects.redrives.start(
        scope: self,
        filters: {
          "actor_type" => actor_type,
          "failed_after" => failed_after_filter(failed_after),
          "limit" => limit_filter(limit)
        },
        authorization_context:
      )
    end

    # @rbs (untyped) -> String?
    def failed_after_filter(failed_after)
      return nil if failed_after.nil?
      raise ArgumentError, "failed_after must be a time" unless failed_after.respond_to?(:utc)

      failed_after.utc.iso8601(6)
    end

    # @rbs (untyped) -> Integer?
    def limit_filter(limit)
      return nil if limit.nil?
      return limit if limit.is_a?(Integer) && limit.positive?

      raise ArgumentError, "limit must be a positive integer"
    end

    # @rbs () -> ActiveRecord::Relation[untyped]
    def dead
      model.where(status: DEAD)
    end

    # @rbs (Hash[String, untyped], ?dead_before: untyped) -> ActiveRecord::Relation[untyped]
    def matching(filters, dead_before: nil)
      relation = dead
      actor_type = filters["actor_type"]
      failed_after = filters["failed_after"]
      relation = relation.joins(:instance).where(Instance.table_name => { actor_type: }) if actor_type
      relation = relation.where(updated_at: Time.parse(failed_after)..) if failed_after
      relation = relation.where(updated_at: ..dead_before) if dead_before
      relation
    end

    # @rbs (Array[untyped]) -> Integer
    def revive_all(identifiers)
      model.where(id: identifiers, status: DEAD).update_all(revival_attributes)
    end

    # @rbs (untyped) -> Integer
    def revive(row)
      model.where(id: row.id, status: DEAD).update_all(revival_attributes).tap do
        row.reload
      end
    end

    # @rbs (Symbol, authorization_context: untyped, ?resource_id: String?) -> void
    def authorize!(action, authorization_context:, resource_id: nil)
      authorized = SolidObjects.configuration.authorize_administration.call(
        action: action.to_s,
        resource: resource,
        resource_id: resource_id,
        authorization_context:
      )
      return if authorized

      raise Unauthorized, "actor administration is not authorized"
    end

    private

    attr_reader :model, :identifier

    # @rbs () -> Hash[Symbol, untyped]
    def revival_attributes
      now = SolidObjects.database_adapter.database_now
      {
        status: PENDING,
        attempt_count: 0,
        available_at: now,
        claimed_by: nil,
        claimed_at: nil,
        updated_at: now
      }
    end
  end
end
