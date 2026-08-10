# rbs_inline: enabled

SolidObjects.configure do |configuration|
  configuration.worker_count = 1
  configuration.effect_worker_count = 1
  configuration.broadcast_worker_count = 1
  configuration.reminder_scheduler_count = 1
  configuration.message_retention = 30.days
  configuration.process_retention = 7.days
  configuration.prune_batch_size = 1_000

  # Override message retention only for actor types with different audit or
  # privacy requirements:
  #
  # configuration.message_retention_by_actor_type = {
  #   "AuditActor" => 365.days,
  #   "EphemeralCounter" => 1.day
  # }
  #
  # Actor instances never expire unless their type is listed here. Expiration
  # removes idle state and completed history, so start with the preview command:
  #
  # configuration.instance_retention_by_actor_type = {
  #   "EphemeralCounter" => 30.days
  # }
  #
  #   bundle exec solid_objects prune_instances

  # Every policy denies by default, so a fresh installation is intentionally
  # inert. Replace these policies before invoking actors.
  #
  # Message and query policies gate direct calls, sync, async, and state reads.
  # Destroy removes an actor and all of its durable work. Subscription gates
  # Action Cable streams. Administration gates engine pages, pruning, and
  # operational commands. Keep the last three denied until their callers are
  # authenticated.
  #
  # Prefer policies that bind actor_type and actor_id to a trusted
  # authorization_context. See:
  # https://github.com/cardmagic/solid_objects/blob/main/docs/authorization.md
  # and run:
  #
  #   bin/rails solid_objects:doctor
  #
  # after configuring the application.
  configuration.authorize_message = ->(**) { false }
  configuration.authorize_query = ->(**) { false }
  configuration.authorize_destroy = ->(**) { false }
  configuration.authorize_subscription = ->(**) { false }
  configuration.authorize_administration = ->(**) { false }

  # Configure component_authorization_context to return the authenticated
  # principal used for reactive component refreshes.

  # On hosts where shell access is already an authenticated administrative
  # boundary, this enables only gem commands that pass the CLI context:
  #
  # configuration.authorize_administration = lambda do |authorization_context:, **|
  #   authorization_context.is_a?(Hash) && authorization_context[:source] == "cli"
  # end

  # Runtime roles poll for work and are woken early by an in-process signal,
  # which cannot reach another process. On PostgreSQL, notifications remove that
  # delay. This opens a connection per waiting thread outside the pool and does
  # not work through a transaction-pooling proxy such as PgBouncer, so it is
  # opt-in:
  #
  # configuration.wake_up_adapter = SolidObjects::WakeUpAdapters.for
end
