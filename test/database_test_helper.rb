# frozen_string_literal: true

require "test_helper"
require "fileutils"

default_database = File.expand_path("../tmp/solid_objects_test_#{Process.pid}.sqlite3", __dir__)
database_url = ENV["SOLID_OBJECTS_DATABASE_URL"]

unless database_url
  FileUtils.mkdir_p(File.dirname(default_database))
  FileUtils.rm_f(default_database)
end

ActiveRecord::Base.establish_connection(
  database_url || {
    adapter: "sqlite3",
    database: default_database,
    pool: 20,
    timeout: 5_000
  }
)
ActiveRecord::Migration.verbose = false

require_relative "../db/migrate/20260805000000_create_solid_objects_tables"
require_relative "../db/migrate/20260806000000_add_state_revision_to_solid_objects_instances"

CreateSolidObjectsTables.new.migrate(:up)
AddStateRevisionToSolidObjectsInstances.new.migrate(:up)

ActiveRecord::Base.connection.create_table(:solid_objects_test_domain_records) do |table|
  table.string :name, null: false
end

require "solid_objects/database_adapter"
require_relative "../app/models/solid_objects/record"
require_relative "../app/models/solid_objects/process"
require_relative "../app/models/solid_objects/instance"
require_relative "../app/models/solid_objects/message"
require_relative "../app/models/solid_objects/ready_message"
require_relative "../app/models/solid_objects/claimed_message"
require_relative "../app/models/solid_objects/reminder"
require_relative "../app/models/solid_objects/effect"
require_relative "../app/models/solid_objects/broadcast"
require_relative "../app/models/solid_objects/dead_letter"

class SolidObjectsTestDomainRecord < ActiveRecord::Base
end

class ActiveSupport::TestCase
  setup do
    SolidObjects::Record.descendants.each(&:reset_column_information)
  end

  teardown do
    SolidObjects::Instance.delete_all
    SolidObjects::Process.delete_all
    SolidObjectsTestDomainRecord.delete_all
  end
end

Minitest.after_run do
  ActiveRecord::Base.connection_pool.disconnect!
  FileUtils.rm_f(default_database) unless database_url
end
