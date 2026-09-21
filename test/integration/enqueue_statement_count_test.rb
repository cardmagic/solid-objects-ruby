# frozen_string_literal: true

require "database_test_helper"

class EnqueueStatementCountTest < ActiveSupport::TestCase
  class CartActor < SolidObjects::Actor
    actor_type "enqueue-statement-count-cart"

    attribute :items, default: -> { [] }

    def add(product_id:)
      self.items += [ product_id ]
    end
  end

  STEADY_STATE_STATEMENT_COUNT = 10

  setup { CartActor.ensure_registered! }

  test "a steady-state enqueue never inserts the instance row" do
    reference = CartActor.ref("alice")
    reference.async.add(product_id: "shirt")

    statements = capture_statements { reference.async.add(product_id: "pants") }

    assert_empty instance_statements(statements).grep(/\AINSERT/i)
  end

  test "a steady-state enqueue touches the instance row three times" do
    reference = CartActor.ref("alice")
    reference.async.add(product_id: "shirt")

    statements = instance_statements(capture_statements { reference.async.add(product_id: "pants") })

    assert_equal 2, statements.grep(/\ASELECT/i).length, statements.inspect
    assert_equal 1, statements.grep(/\AUPDATE/i).length, statements.inspect
    assert_equal 3, statements.length, statements.inspect
  end

  test "a steady-state enqueue opens one transaction and never restarts it" do
    reference = CartActor.ref("alice")
    reference.async.add(product_id: "shirt")

    statements = capture_statements { reference.async.add(product_id: "pants") }
    control = statements.grep(/\A(?:BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/i)

    assert_empty control.grep(/ROLLBACK|SAVEPOINT/i), statements.inspect
    assert_equal 2, control.length, statements.inspect
  end

  test "a steady-state enqueue issues a fixed number of statements" do
    reference = CartActor.ref("alice")
    reference.async.add(product_id: "shirt")

    statements = capture_statements { reference.async.add(product_id: "pants") }

    assert_equal STEADY_STATE_STATEMENT_COUNT, statements.length, statements.inspect
  end

  private

  def instance_statements(statements)
    statements.grep(/solid_objects_instances/)
  end

  def capture_statements
    statements = []
    subscriber = lambda do |*arguments|
      payload = arguments.last
      next if payload[:name] == "SCHEMA"
      next if payload[:cached]

      statements << payload.fetch(:sql).to_s.strip
    end
    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { yield }
    statements
  end
end
