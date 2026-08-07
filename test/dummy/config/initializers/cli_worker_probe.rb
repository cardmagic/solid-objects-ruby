# frozen_string_literal: true

if ENV["SOLID_OBJECTS_CLI_WORKER_PROBE"]
  ActiveSupport::Notifications.subscribe("solid_objects.message.completed") do |event|
    next unless event.payload.fetch(:actor_type) == "CliWorkerActor"

    File.write(ENV.fetch("SOLID_OBJECTS_CLI_WORKER_PROBE"), event.payload.fetch(:message_id))
    Process.kill("TERM", Process.pid)
  end
end
