# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"

require_relative "config/environment"
require "solid_objects/schema_bootstrap"

SolidObjects::SchemaBootstrap.install

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
  operation: "complete",
  delivery_mode: "async",
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
