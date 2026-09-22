# rbs_inline: enabled

module SolidObjects
  module AdministrationAudit
    module_function

    # @rbs (action: String, kind: String, ?subject_id: untyped, ?filters: Hash[Symbol | String, untyped]?, ?actor: String?) -> void
    def record(action:, kind:, subject_id: nil, filters: nil, actor: nil)
      AdministrationEvent.create!(
        action:,
        kind:,
        subject_id: subject_id&.to_s,
        filters:,
        actor:,
        occurred_at: SolidObjects.database_adapter.database_now
      )
      nil
    end

    # @rbs (untyped) -> String?
    def identity(authorization_context)
      return nil if authorization_context.nil?

      SolidObjects.configuration.administration_identity
        .call(authorization_context)
        &.to_s
        &.byteslice(0, 255)
    end
  end
end
