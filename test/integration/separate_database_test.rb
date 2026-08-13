# frozen_string_literal: true

require "database_test_helper"
require "tmpdir"

class SeparateDatabaseTest < ActiveSupport::TestCase
  class SeparateDatabaseActor < SolidObjects::Actor
    actor_type "separate-database"

    attribute :completed, default: false

    def complete
      self.completed = true
      commit_action :write_application_database
    end
  end

  test "commit actions fail safely when actor state uses a separate database" do
    Dir.mktmpdir do |directory|
      database = File.join(directory, "actors.sqlite3")
      connect_solid_objects_to(database)
      SolidObjects.configuration.max_attempts = 1
      SolidObjects.register_commit_action(:write_application_database) do
        SolidObjectsTestDomainRecord.create!(name: "escaped")
      end

      error = assert_raises(SolidObjects::MessageFailed) do
        SeparateDatabaseActor.ref("one").complete
      end

      assert_equal "SolidObjects::CommitActionUnavailable", error.details.fetch("class")
      assert_empty SolidObjectsTestDomainRecord.all
      assert_equal(
        {},
        SolidObjects::Instance.find_by!(
          actor_type: "separate-database",
          actor_id: "one"
        ).state
      )
    ensure
      restore_solid_objects_connection
    end
  end

  private

  def connect_solid_objects_to(database)
    SolidObjects.reset_caller_process!
    SolidObjects::Record.establish_connection(
      adapter: "sqlite3",
      database:,
      pool: 10,
      timeout: 5_000
    )
    [
      CreateSolidObjectsTables,
      AddStateRevisionToSolidObjectsInstances,
      RenameMessageDispatchColumns
    ].each do |migration_class|
      migration = migration_class.new
      migration.define_singleton_method(:connection) { SolidObjects::Record.connection }
      migration.migrate(:up)
    end
    SolidObjects.reset!
    authorize_all_actor_operations
    SolidObjects::Record.descendants.each(&:reset_column_information)
  end

  def restore_solid_objects_connection
    SolidObjects.reset_caller_process!
    SolidObjects::Record.connection_pool.disconnect!
    SolidObjects::Record.remove_connection
    SolidObjects.reset!
    authorize_all_actor_operations
    SolidObjects::Record.descendants.each(&:reset_column_information)
  end

  def authorize_all_actor_operations
    SolidObjects.configuration.authorize_message = ->(**) { true }
    SolidObjects.configuration.authorize_query = ->(**) { true }
    SolidObjects.configuration.authorize_destroy = ->(**) { true }
  end
end
