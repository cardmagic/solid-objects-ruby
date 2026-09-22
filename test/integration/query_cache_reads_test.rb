# frozen_string_literal: true

require "database_test_helper"

class QueryCacheReadsTest < ActiveSupport::TestCase
  class CounterActor < SolidObjects::Actor
    actor_type "query-cache-counter"

    attribute :count, default: 0

    def increment
      self.count += 1
    end
  end

  setup { CounterActor.ensure_registered! }

  def from_another_connection
    Thread.new do
      SolidObjects::Record.connection_pool.with_connection { yield }
    end.join
  end

  test "message status refreshes while a query cache is open" do
    message = CounterActor.ref("alice").async.increment

    ActiveRecord::Base.cache do
      assert_equal "ready", message.status

      from_another_connection do
        SolidObjects::ReadyMessage.where(message_id: message.id).delete_all
        SolidObjects::Message.find(message.id).update!(completed_at: Time.current)
      end

      assert_equal "completed", message.status
    end
  end

  test "message result refreshes while a query cache is open" do
    message = CounterActor.ref("alice").async.increment

    ActiveRecord::Base.cache do
      assert_nil message.result

      from_another_connection do
        SolidObjects::Message.find(message.id).update!(result: { "value" => 7 })
      end

      assert_equal({ "value" => 7 }, message.result)
    end
  end

  test "an actor snapshot refreshes while a query cache is open" do
    reference = CounterActor.ref("alice")
    reference.async.increment
    SolidObjects::Worker.new.run_until_idle

    ActiveRecord::Base.cache do
      assert_equal 1, reference.snapshot.count

      from_another_connection do
        instance = SolidObjects::Instance.find_by!(actor_type: "query-cache-counter", actor_id: "alice")
        instance.update!(state: instance.state.merge("count" => 9))
      end

      assert_equal 9, reference.snapshot.count
    end
  end
end
