# rbs_inline: enabled

module SolidObjects
  class DeadLetterScope
    DEAD = "dead"
    PENDING = "pending"

    # @rbs @model: untyped
    # @rbs @resource: String
    # @rbs @identifier: Symbol

    attr_reader :resource

    # @rbs (model: untyped, resource: String, identifier: Symbol, kind: String) -> void
    def initialize(model:, resource:, identifier:, kind:)
      @model = model
      @resource = resource
      @identifier = identifier
      @kind = kind
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
        authorization_context:
      )
      return row unless row.status == DEAD

      revive(row)
      row
    end

    # @rbs () -> ActiveRecord::Relation[untyped]
    def dead
      model.where(status: DEAD)
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

    attr_reader :model, :identifier, :kind

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
