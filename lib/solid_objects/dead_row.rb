# rbs_inline: enabled

module SolidObjects
  DeadRow = Data.define(
    :id,
    :kind,
    :actor_type,
    :actor_id,
    :status,
    :attempt_count,
    :available_at,
    :failed_at,
    :error
  )
end
