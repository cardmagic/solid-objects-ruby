# rbs_inline: enabled

SolidObjects.configure do |configuration|
  configuration.worker_count = 1
  configuration.effect_worker_count = 1
  configuration.broadcast_worker_count = 1
  configuration.reminder_scheduler_count = 1
  configuration.authorize_message = ->(**) { false }
  configuration.authorize_query = ->(**) { false }
  configuration.authorize_subscription = ->(**) { false }
  configuration.authorize_administration = ->(**) { false }
end
