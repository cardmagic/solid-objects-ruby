# rbs_inline: enabled

require "bundler/setup"
require "active_record"
require "solid_objects"

# Boots a standalone runtime against a shared SQLite file, the way the
# demo's parent and its crashing children all attach to one database.
module AtLeastOnceBoot
  ROOT = File.expand_path("../..", __dir__)

  # @rbs (String database_path) -> void
  def self.call(database_path)
    ActiveRecord::Base.establish_connection(
      adapter: "sqlite3",
      database: database_path,
      pool: 5,
      timeout: 5_000
    )
    ActiveRecord::Migration.verbose = false
    migrate unless ActiveRecord::Base.connection.table_exists?("solid_objects_instances")

    require "solid_objects/database_adapter"
    %w[
      record process instance message ready_message claimed_message
      reminder effect effect_recovery broadcast dead_letter
    ].each { |model| require File.join(ROOT, "app/models/solid_objects", model) }

    SolidObjects.configuration.authorize_message = ->(**) { true }
    SolidObjects.configuration.authorize_query = ->(**) { true }
    SolidObjects.configuration.polling_interval = 0.01
    SolidObjects.configuration.process_heartbeat_interval = 0.075
    SolidObjects.configuration.process_alive_threshold = 0.3
    SolidObjects.configuration.lease_duration = 0.25
    SolidObjects.configuration.lease_renewal_interval = 0.05
  end

  # @rbs () -> void
  def self.migrate
    require "solid_objects/schema_bootstrap"
    SolidObjects::SchemaBootstrap.install
  end
end
