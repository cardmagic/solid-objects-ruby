# frozen_string_literal: true

require "database_test_helper"
require "active_job"
require "solid_objects/test_helper"

ActiveJob::Base.queue_adapter = :test
ActiveJob::Base.logger = Logger.new(nil)

class ApplicationRecord < ActiveRecord::Base
  self.abstract_class = true
end

class ApplicationJob < ActiveJob::Base
end

module GuideSchema
  def self.create
    connection = ActiveRecord::Base.connection

    connection.create_table(:events, if_not_exists: true) do |table|
      table.integer :seats_available, null: false, default: 0
    end

    connection.create_table(:accounts, if_not_exists: true) do |table|
      table.integer :balance_cents, null: false, default: 0
      table.integer :next_sequence, null: false, default: 1
    end

    connection.create_table(:orders, if_not_exists: true) do |table|
      table.string :reference, null: false
      table.integer :total_cents, null: false
    end

    connection.create_table(:outbox_messages, if_not_exists: true) do |table|
      table.string :name, null: false
      table.json :arguments, null: false
      table.datetime :delivered_at
    end
  end

  def self.reset
    [ "events", "accounts", "orders", "outbox_messages" ].each do |table|
      ActiveRecord::Base.connection.execute("DELETE FROM #{table}")
    end
  end
end

GuideSchema.create

module GuideTestSupport
  def reminder_due_at(actor_id:, operation:, key:)
    SolidObjects::Reminder.find_by(actor_id:, name: "#{operation}:#{key}")&.next_run_at
  end

  def concurrently(count, prepare: ->(index) { index })
    ready = Queue.new
    start = Queue.new
    results = Queue.new
    errors = Queue.new
    connection_slots = Queue.new
    [ count, ActiveRecord::Base.connection_pool.size - 1 ].min.times { connection_slots << true }
    threads = count.times.map do |index|
      Thread.new do
        prepared = ActiveRecord::Base.connection_pool.with_connection { prepare.call(index) }
        ready << true
        start.pop
        connection_slots.pop
        begin
          results << ActiveRecord::Base.connection_pool.with_connection { yield(prepared) }
        ensure
          connection_slots << true
        end
      rescue => error
        ready << true
        errors << error
      end
    end
    count.times { ready.pop }
    count.times { start << true }
    threads.each(&:join)
    raise errors.pop unless errors.empty?

    Array.new(results.size) { results.pop }
  end
end
