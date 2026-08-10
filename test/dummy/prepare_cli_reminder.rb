# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"

require_relative "config/environment"
require_relative "../../db/migrate/20260805000000_create_solid_objects_tables"
require_relative "../../db/migrate/20260806000000_add_state_revision_to_solid_objects_instances"

CreateSolidObjectsTables.new.migrate(:up)
AddStateRevisionToSolidObjectsInstances.new.migrate(:up)

# A reminder that is already due, so the scheduler claims and enqueues it on
# its first pass rather than waiting.
instance = SolidObjects::Instance.create!(
  actor_type: "CliWorkerActor",
  actor_id: "reminder-in-worker",
  state: {},
  state_version: 1
)
reminder = SolidObjects::Reminder.create!(
  instance:,
  actor_type: instance.actor_type,
  actor_id: instance.actor_id,
  name: "deliver_push",
  message_name: "complete",
  arguments: {},
  next_run_at: 1.minute.ago,
  status: "scheduled"
)

puts reminder.id
