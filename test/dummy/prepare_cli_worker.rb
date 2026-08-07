# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"

require_relative "config/environment"
require_relative "../../db/migrate/20260805000000_create_solid_objects_tables"
require_relative "../../db/migrate/20260806000000_add_state_revision_to_solid_objects_instances"

CreateSolidObjectsTables.new.migrate(:up)
AddStateRevisionToSolidObjectsInstances.new.migrate(:up)

now = Time.current
instance = SolidObjects::Instance.create!(
  actor_type: "CliWorkerActor",
  actor_id: "only-in-app-actors",
  state: {},
  state_version: 1
)
message = SolidObjects::Message.create!(
  instance:,
  actor_type: instance.actor_type,
  actor_id: instance.actor_id,
  message_name: "complete",
  message_kind: "async",
  arguments: {},
  sequence: 1,
  max_attempts: 1,
  request_id: SecureRandom.uuid,
  enqueued_at: now,
  available_at: now
)
SolidObjects::ReadyMessage.create!(
  message:,
  instance:,
  sequence: message.sequence,
  available_at: now
)

puts message.id
