# rbs_inline: enabled

require_relative "../../app/models/solid_objects/record"

module SolidObjects
  class Engine < ::Rails::Engine
    isolate_namespace SolidObjects

    config.generators do |generators|
      generators.test_framework :minitest
    end

    initializer "solid_objects.configuration" do
      SolidObjects.configuration.validate!
      SolidObjects::LogSubscriber.install
    end

    initializer "solid_objects.database", after: :load_config_initializers do
      SolidObjects::Record.configure_connection
    end

    initializer "solid_objects.helpers" do
      ActiveSupport.on_load(:action_view) do
        include SolidObjects::ActorHelper
      end
    end

    rake_tasks do
      tasks_path = File.expand_path("../tasks", __dir__)
      Dir[File.join(tasks_path, "**/*.rake")].sort.each { |task| load task }
    end
  end
end
