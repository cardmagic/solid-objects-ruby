# rbs_inline: enabled

require "rails/generators"

module SolidObjects
  module Generators
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      # @rbs () -> void
      def copy_initializer
        template "solid_objects.rb", "config/initializers/solid_objects.rb"
      end

      # @rbs () -> void
      def copy_migrations
        rake "railties:install:migrations FROM=solid_objects"
      end
    end
  end
end
