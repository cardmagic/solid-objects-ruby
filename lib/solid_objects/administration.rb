# rbs_inline: enabled

module SolidObjects
  class Administration
    # @rbs (?authorization_context: untyped) -> Array[Hash[Symbol, untyped]]
    def processes(authorization_context: nil)
      authorize!(authorization_context:)
      now = SolidObjects.database_adapter.database_now
      stale_at = now - SolidObjects.configuration.process_alive_threshold

      Process.order(:kind, :started_at).map do |process_record|
        {
          id: process_record.id,
          kind: process_record.kind,
          hostname: process_record.hostname,
          pid: process_record.pid,
          metadata: Serialization.readonly_copy(process_record.metadata),
          shutdown_state: process_record.shutdown_state,
          shutdown_requested_at: process_record.shutdown_requested_at,
          started_at: process_record.started_at,
          last_heartbeat_at: process_record.last_heartbeat_at,
          stopped_at: process_record.stopped_at,
          stale: process_record.shutdown_state != "stopped" &&
            process_record.last_heartbeat_at <= stale_at
        }.freeze
      end.freeze
    end

    private

    # @rbs (?authorization_context: untyped) -> void
    def authorize!(authorization_context: nil)
      authorized = SolidObjects.configuration.authorize_administration.call(
        action: :inspect,
        resource: "processes",
        resource_id: nil,
        authorization_context:
      )
      return if authorized

      raise Unauthorized, "actor administration is not authorized"
    end
  end
end
