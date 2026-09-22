# rbs_inline: enabled

module SolidObjects
  RedriveTask = Data.define(
    :id, :kind, :filters, :status, :moved, :remaining, :started_at, :finished_at
  ) do
    # @rbs (?authorization_context: untyped) -> RedriveTask
    def cancel(authorization_context: nil)
      SolidObjects.redrives.cancel(id, authorization_context:)
    end
  end
end
