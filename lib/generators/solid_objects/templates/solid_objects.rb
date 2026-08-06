# rbs_inline: enabled

SolidObjects.configure do |configuration|
  configuration.worker_count = 1
  configuration.effect_worker_count = 1
  configuration.broadcast_worker_count = 1
  configuration.reminder_scheduler_count = 1

  # Every policy denies by default, so a fresh installation is intentionally
  # inert. Replace these policies before invoking actors.
  #
  # Message and query policies gate direct calls, sync, async, and state reads.
  # Destroy removes an actor and all of its durable work. Subscription gates
  # Action Cable streams. Administration gates engine pages and operational
  # commands. Keep the last three denied until their callers are authenticated.
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
end
