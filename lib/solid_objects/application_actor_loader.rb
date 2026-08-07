# rbs_inline: enabled

module SolidObjects
  class ApplicationActorLoader
    # @rbs @application: untyped
    # @rbs @autoloader: untyped

    # @rbs (?application: untyped, ?autoloader: untyped) -> void
    def initialize(application: Rails.application, autoloader: Rails.autoloaders.main)
      @application = application
      @autoloader = autoloader
    end

    # @rbs () -> void
    def call
      actor_directories.each { |directory| autoloader.eager_load_dir(directory) }
      current_actor_classes.each(&:ensure_registered!)
    end

    # @rbs () -> void
    def install
      application.reloader.to_prepare { call }
      call
    end

    private

    attr_reader :application, :autoloader

    # @rbs () -> Array[String]
    def actor_directories
      configured_directories = application.paths["app/actors"]&.existent || []
      conventional_directories = application.paths["app"].existent.select do |application_directory|
        File.basename(application_directory) == "actors"
      end
      managed_directories = autoloader.dirs.map { |directory| File.expand_path(directory) }

      (configured_directories + conventional_directories)
        .select { |directory| Dir.exist?(directory) }
        .map { |directory| File.expand_path(directory) }
        .select { |directory| managed_directories.include?(directory) }
        .uniq
    end

    # @rbs () -> Array[Class]
    def current_actor_classes
      Actor.descendants.select do |actor_class|
        actor_class.name &&
          actor_class.name.safe_constantize.equal?(actor_class)
      end
    end
  end
end
