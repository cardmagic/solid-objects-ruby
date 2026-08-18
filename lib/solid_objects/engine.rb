# rbs_inline: enabled

module SolidObjects
  class Engine < ::Rails::Engine
    RECORD_PATH = File.expand_path("../../app/models/solid_objects/record.rb", __dir__)

    isolate_namespace SolidObjects

    config.generators do |generators|
      generators.test_framework :minitest
    end

    initializer "solid_objects.configuration" do
      SolidObjects.configuration.validate!
      SolidObjects::LogSubscriber.install
    end

    initializer "solid_objects.database", after: :load_config_initializers do
      ActiveSupport.on_load(:active_record) do
        require RECORD_PATH
      end
    end

    initializer "solid_objects.helpers" do
      ActiveSupport.on_load(:action_view) do
        require_relative "../../app/helpers/solid_objects/actor_helper"
        include SolidObjects::ActorHelper
      end
    end

    initializer "solid_objects.assets" do |application|
      next unless application.config.respond_to?(:assets)
      next unless application.config.assets.respond_to?(:precompile)

      application.config.assets.precompile << "solid_objects/component_refresh.js"
    end

    rake_tasks do
      tasks_path = File.expand_path("../tasks", __dir__)
      Dir[File.join(tasks_path, "**/*.rake")].sort.each { |task| load task }
    end
  end
end
