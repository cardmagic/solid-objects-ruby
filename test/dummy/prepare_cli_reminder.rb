# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"

require_relative "config/environment"
require "solid_objects/schema_bootstrap"

SolidObjects::SchemaBootstrap.install

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
  operation: "complete",
  arguments: {},
  next_run_at: 1.minute.ago,
  status: "scheduled"
)

puts reminder.id
