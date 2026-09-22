# rbs_inline: enabled

require "digest"

module SolidObjects
  class RedriveManager
    RUNNING = "running"
    COMPLETED = "completed"
    CANCELLED = "cancelled"

    # @rbs (scope: DeadLetterScope, filters: Hash[String, untyped], authorization_context: untyped) -> RedriveTask
    def start(scope:, filters:, authorization_context:)
      scope.authorize!(:redrive, authorization_context:)
      active_scope = active_scope_for(kind: scope.kind, filters:)
      running = Redrive.find_by(active_scope:)
      return task_for(running) if running

      task_for(open_task(scope:, filters:, active_scope:, authorization_context:))
    rescue ActiveRecord::RecordNotUnique
      task_for(Redrive.find_by!(active_scope:))
    end

    # @rbs (String, ?authorization_context: untyped) -> RedriveTask
    def find(id, authorization_context: nil)
      authorize!(:inspect, authorization_context:, resource_id: id)
      task_for(Redrive.find(id))
    end

    # @rbs (?status: Symbol | String | nil, ?authorization_context: untyped) -> Array[RedriveTask]
    def all(status: nil, authorization_context: nil)
      authorize!(:inspect, authorization_context:)
      relation = Redrive.order(started_at: :desc, id: :desc)
      relation = relation.where(status: status.to_s) if status
      relation.map { |record| task_for(record) }
    end

    # @rbs (String, ?authorization_context: untyped) -> RedriveTask
    def cancel(id, authorization_context: nil)
      authorize!(:cancel, authorization_context:, resource_id: id)
      record = Redrive.find(id)
      return task_for(record) unless record.status == RUNNING

      audit(record, action: "redrive.cancel") if close(record, status: CANCELLED)
      task_for(record)
    end

    # @rbs (Redrive, status: String) -> bool
    def close(record, status:)
      changed = Redrive.where(id: record.id, status: RUNNING).update_all(
        status:,
        active_scope: nil,
        finished_at: SolidObjects.database_adapter.database_now,
        updated_at: SolidObjects.database_adapter.database_now
      )
      record.reload if changed.positive?
      changed.positive?
    end

    # @rbs (Redrive, action: String) -> void
    def audit(record, action:)
      AdministrationAudit.record(
        action:,
        kind: record.kind,
        subject_id: record.id,
        filters: record.filters,
        actor: record.actor
      )
    end

    # @rbs (Redrive) -> RedriveTask
    def task_for(record)
      RedriveTask.new(
        id: record.id,
        kind: record.kind,
        filters: Serialization.readonly_copy(record.filters),
        status: record.status,
        moved: record.moved,
        remaining: remaining_for(record),
        started_at: record.started_at,
        finished_at: record.finished_at
      )
    end

    private

    # @rbs (scope: DeadLetterScope, filters: Hash[String, untyped], active_scope: String, authorization_context: untyped) -> Redrive
    def open_task(scope:, filters:, active_scope:, authorization_context:)
      record = Redrive.create!(
        id: "redrive_#{SecureRandom.uuid}",
        kind: scope.kind,
        filters:,
        status: RUNNING,
        active_scope:,
        moved: 0,
        move_limit: filters["limit"],
        actor: AdministrationAudit.identity(authorization_context),
        started_at: SolidObjects.database_adapter.database_now
      )
      audit(record, action: "redrive.start")
      record
    end

    # @rbs (Redrive) -> Integer
    def remaining_for(record)
      return 0 unless record.status == RUNNING

      matching = DeadLetterScope
        .for_kind(record.kind)
        .matching(record.filters, dead_before: record.started_at)
        .count
      limit = record.move_limit
      return matching unless limit

      [ matching, limit - record.moved ].min
    end

    # @rbs (kind: String, filters: Hash[String, untyped]) -> String
    def active_scope_for(kind:, filters:)
      "#{kind}:#{Digest::SHA256.hexdigest(filters.to_json)}"
    end

    # @rbs (Symbol, authorization_context: untyped, ?resource_id: String?) -> void
    def authorize!(action, authorization_context:, resource_id: nil)
      authorized = SolidObjects.configuration.authorize_administration.call(
        action: action.to_s,
        resource: "redrives",
        resource_id:,
        authorization_context:
      )
      return if authorized

      raise Unauthorized, "actor administration is not authorized"
    end
  end
end
