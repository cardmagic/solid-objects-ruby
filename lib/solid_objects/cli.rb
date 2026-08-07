# rbs_inline: enabled

require "thor"
require "solid_objects/application_actor_loader"

module SolidObjects
  class CLI < Thor
    package_name "solid_objects"

    desc "start", "Start actor, effect, reminder, and broadcast processes"
    option :environment, type: :string, aliases: "-e"
    option :workers, type: :numeric
    option :effect_workers, type: :numeric
    option :broadcast_workers, type: :numeric
    option :reminder_schedulers, type: :numeric

    # @rbs () -> void
    def start
      boot_application
      supervisor = Supervisor.new(
        worker_count: numeric_option(:workers, SolidObjects.configuration.worker_count),
        effect_worker_count: numeric_option(:effect_workers, SolidObjects.configuration.effect_worker_count),
        broadcast_worker_count: numeric_option(:broadcast_workers, SolidObjects.configuration.broadcast_worker_count),
        reminder_scheduler_count: numeric_option(:reminder_schedulers, SolidObjects.configuration.reminder_scheduler_count)
      )
      %w[INT TERM].each do |signal|
        Signal.trap(signal) { Thread.new { supervisor.stop } }
      end
      supervisor.run
    end

    desc "status", "Print registered runtime processes"
    option :environment, type: :string, aliases: "-e"

    # @rbs () -> void
    def status
      boot_application
      authorize_administration!(:status, resource: "processes")
      rows = SolidObjects::Process.order(:kind, :started_at).map do |process_record|
        {
          id: process_record.id,
          kind: process_record.kind,
          hostname: process_record.hostname,
          pid: process_record.pid,
          state: process_record.shutdown_state,
          last_heartbeat_at: process_record.last_heartbeat_at
        }
      end
      puts JSON.pretty_generate(rows)
    end

    desc "cleanup", "Release coordination records owned by dead processes"
    option :environment, type: :string, aliases: "-e"

    # @rbs () -> void
    def cleanup
      boot_application
      authorize_administration!(:cleanup, resource: "processes")
      puts JSON.generate(cleaned_processes: ProcessRegistry.cleanup_dead)
    end

    desc "prune_messages", "Preview or delete expired terminal message history"
    option :environment, type: :string, aliases: "-e"
    option :execute, type: :boolean, default: false

    # @rbs () -> void
    def prune_messages
      boot_application
      authorize_administration!(:prune, resource: "messages")
      pruner = MessagePruner.new
      count = options[:execute] ? pruner.prune : pruner.preview
      puts JSON.generate(mode: options[:execute] ? "execute" : "preview", messages: count)
    end

    desc "prune_instances", "Preview or delete expired idle actor instances"
    option :environment, type: :string, aliases: "-e"
    option :execute, type: :boolean, default: false

    # @rbs () -> void
    def prune_instances
      boot_application
      authorize_administration!(:prune, resource: "instances")
      pruner = InstancePruner.new
      count = options[:execute] ? pruner.prune : pruner.preview
      puts JSON.generate(mode: options[:execute] ? "execute" : "preview", instances: count)
    end

    desc "prune_processes", "Preview or delete expired stopped process records"
    option :environment, type: :string, aliases: "-e"
    option :execute, type: :boolean, default: false

    # @rbs () -> void
    def prune_processes
      boot_application
      authorize_administration!(:prune, resource: "processes")
      pruner = ProcessPruner.new
      count = options[:execute] ? pruner.prune : pruner.preview
      puts JSON.generate(mode: options[:execute] ? "execute" : "preview", processes: count)
    end

    desc "dead_letters", "Print dead actor messages"
    option :environment, type: :string, aliases: "-e"

    # @rbs () -> void
    def dead_letters
      boot_application
      rows = SolidObjects.dead_letters
        .all(authorization_context: { source: "cli" })
        .map(&:attributes)
      puts JSON.pretty_generate(rows)
    end

    desc "retry_dead_letter ID", "Retry one dead actor message"
    option :environment, type: :string, aliases: "-e"

    # @rbs (String) -> void
    def retry_dead_letter(id)
      boot_application
      message_reference = SolidObjects.dead_letters.retry(
        Integer(id),
        authorization_context: { source: "cli" }
      )
      puts JSON.generate(message_id: message_reference.id)
    end

    private

    # @rbs () -> void
    def boot_application
      path = options[:environment] ||
        File.expand_path("config/environment.rb", Dir.pwd)
      unless File.file?(path)
        raise Error, "Rails environment not found at #{path}"
      end

      require path
      ApplicationActorLoader.new.install
    end

    # @rbs (Symbol, Integer) -> Integer
    def numeric_option(name, default)
      value = options[name]
      value ? Integer(value) : default
    end

    # @rbs (Symbol, resource: String) -> void
    def authorize_administration!(action, resource:)
      authorized = SolidObjects.configuration.authorize_administration.call(
        action:,
        resource:,
        resource_id: nil,
        authorization_context: { source: "cli" }
      )
      return if authorized

      raise Unauthorized, "actor administration is not authorized"
    end
  end
end
