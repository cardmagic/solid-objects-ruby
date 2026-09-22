# frozen_string_literal: true

require "database_test_helper"

class RedriveTest < ActiveSupport::TestCase
  class PaymentActor < SolidObjects::Actor
    actor_type "redrive-payments"

    attribute :placed, default: 0

    def place(order:)
      self.placed += 1
      emit :settle, order: order
    end
  end

  class ShipmentActor < SolidObjects::Actor
    actor_type "redrive-shipments"

    attribute :count, default: 0

    observable :count

    def touch
      self.count += 1
    end
  end

  setup do
    SolidObjects.configuration.retry_delay = ->(_attempt) { 0 }
    SolidObjects.configuration.authorize_administration = ->(**) { true }
    SolidObjects.configuration.redrive_batch_size = 10
    SolidObjects.configuration.redrive_batch_pause = 0
  end

  test "moves every matching row in bounded batches" do
    dead_effects(25)

    task = SolidObjects.dead_letters.effects.redrive(authorization_context: "operator")
    runner = SolidObjects::RedriveRunner.new

    assert_equal "running", task.status
    assert runner.run_once
    assert_equal 10, SolidObjects::Effect.where(status: "pending").count
    assert runner.run_once
    assert_equal 20, SolidObjects::Effect.where(status: "pending").count
    assert runner.run_once
    assert_equal 25, SolidObjects::Effect.where(status: "pending").count

    refute runner.run_once
    finished = SolidObjects.redrives.find(task.id, authorization_context: "operator")
    assert_equal "completed", finished.status
    assert_equal 25, finished.moved
    assert_equal 0, finished.remaining
  end

  test "stops at the limit and leaves the rest dead" do
    dead_effects(25)

    task = SolidObjects.dead_letters.effects.redrive(limit: 15, authorization_context: "operator")
    drain

    finished = SolidObjects.redrives.find(task.id, authorization_context: "operator")
    assert_equal 15, finished.moved
    assert_equal "completed", finished.status
    assert_equal 10, SolidObjects::Effect.where(status: "dead").count
  end

  test "returns the running task when the same scope is redriven again" do
    dead_effects(25)

    first = SolidObjects.dead_letters.effects.redrive(authorization_context: "operator")
    second = SolidObjects.dead_letters.effects.redrive(authorization_context: "operator")

    assert_equal first.id, second.id
    assert_equal 1, SolidObjects::Redrive.count
  end

  test "starts a separate task for another scope while one runs" do
    dead_effects(5)
    dead_broadcast

    effects_task = SolidObjects.dead_letters.effects.redrive(authorization_context: "operator")
    broadcasts_task = SolidObjects.dead_letters.broadcasts.redrive(authorization_context: "operator")

    refute_equal effects_task.id, broadcasts_task.id
    assert_equal [ "broadcast", "effect" ], SolidObjects::Redrive.pluck(:kind).sort
  end

  test "starts a separate task for different filters" do
    dead_effects(5)

    first = SolidObjects.dead_letters.effects.redrive(authorization_context: "operator")
    second = SolidObjects.dead_letters.effects.redrive(
      actor_type: "redrive-payments",
      authorization_context: "operator"
    )

    refute_equal first.id, second.id
  end

  test "starts a new task once the first finishes" do
    dead_effects(5)
    first = SolidObjects.dead_letters.effects.redrive(authorization_context: "operator")
    drain
    SolidObjects::Effect.where.not(status: "dead").update_all(
      status: "dead", updated_at: SolidObjects.database_adapter.database_now
    )

    second = SolidObjects.dead_letters.effects.redrive(authorization_context: "operator")

    refute_equal first.id, second.id
    assert_equal "running", second.status
  end

  test "cancels a running task and keeps the rows it already moved" do
    dead_effects(25)
    task = SolidObjects.dead_letters.effects.redrive(authorization_context: "operator")
    runner = SolidObjects::RedriveRunner.new
    runner.run_once

    task.cancel(authorization_context: "operator")

    refute runner.run_once
    cancelled = SolidObjects.redrives.find(task.id, authorization_context: "operator")
    assert_equal "cancelled", cancelled.status
    assert_equal 10, cancelled.moved
    assert_equal 10, SolidObjects::Effect.where(status: "pending").count
    assert_equal 15, SolidObjects::Effect.where(status: "dead").count
  end

  test "does not move a row that died after the task started" do
    dead_effects(2)
    task = SolidObjects.dead_letters.effects.redrive(authorization_context: "operator")
    sleep 0.01
    PaymentActor.ref("late").async.place(order: "late")
    run_actors
    SolidObjects::Effect.where.not(status: "dead").update_all(
      status: "dead", updated_at: SolidObjects.database_adapter.database_now
    )

    drain

    assert_equal 2, SolidObjects.redrives.find(task.id, authorization_context: "operator").moved
    assert_equal 1, SolidObjects::Effect.where(status: "dead").count
  end

  test "filters by actor type" do
    dead_effects(3)
    ShipmentActor.ref("one").async.touch
    run_actors

    task = SolidObjects.dead_letters.effects.redrive(
      actor_type: "redrive-shipments",
      authorization_context: "operator"
    )
    drain

    finished = SolidObjects.redrives.find(task.id, authorization_context: "operator")
    assert_equal 0, finished.moved
    assert_equal 3, SolidObjects::Effect.where(status: "dead").count
  end

  test "filters by failure time" do
    dead_effects(3)
    future = SolidObjects.database_adapter.database_now + 60

    task = SolidObjects.dead_letters.effects.redrive(
      failed_after: future,
      authorization_context: "operator"
    )
    drain

    assert_equal 0, SolidObjects.redrives.find(task.id, authorization_context: "operator").moved
  end

  test "reads tasks back by id and by status" do
    dead_effects(5)
    task = SolidObjects.dead_letters.effects.redrive(authorization_context: "operator")

    running = SolidObjects.redrives.all(status: :running, authorization_context: "operator")
    assert_equal [ task.id ], running.map(&:id)

    drain

    assert_empty SolidObjects.redrives.all(status: :running, authorization_context: "operator")
    completed = SolidObjects.redrives.all(status: :completed, authorization_context: "operator")
    assert_equal [ task.id ], completed.map(&:id)
    assert_equal [ task.id ], SolidObjects.redrives.all(authorization_context: "operator").map(&:id)
  end

  test "writes one audit row for each task transition" do
    dead_effects(5)

    task = SolidObjects.dead_letters.effects.redrive(authorization_context: "operator")
    drain

    events = SolidObjects::AdministrationEvent.order(:id).map(&:action)
    assert_equal [ "redrive.start", "redrive.finish" ], events
    assert_equal [ task.id, task.id ], SolidObjects::AdministrationEvent.order(:id).map(&:subject_id)
    assert_equal({ "actor_type" => nil, "failed_after" => nil, "limit" => nil },
      SolidObjects::AdministrationEvent.order(:id).first.filters)
  end

  test "writes one audit row when a task is cancelled" do
    dead_effects(5)
    task = SolidObjects.dead_letters.effects.redrive(authorization_context: "operator")

    task.cancel(authorization_context: "operator")

    assert_equal [ "redrive.start", "redrive.cancel" ],
      SolidObjects::AdministrationEvent.order(:id).map(&:action)
  end

  test "refuses an invalid filter rather than redrive everything" do
    dead_effects(2)

    assert_raises(ArgumentError) do
      SolidObjects.dead_letters.effects.redrive(limit: 0, authorization_context: "operator")
    end
    assert_raises(ArgumentError) do
      SolidObjects.dead_letters.effects.redrive(limit: 1.5, authorization_context: "operator")
    end

    assert_equal 0, SolidObjects::Redrive.count
    assert_equal 0, SolidObjects::AdministrationEvent.count
  end

  test "writes no audit row when a retry names a row that does not exist" do
    assert_raises(ActiveRecord::RecordNotFound) do
      SolidObjects.dead_letters.effects.retry("missing", authorization_context: "operator")
    end

    assert_equal 0, SolidObjects::AdministrationEvent.count
  end

  test "a cancel cannot overwrite a task the runner already finished" do
    dead_effects(1)
    task = SolidObjects.dead_letters.effects.redrive(authorization_context: "operator")
    drain

    task.cancel(authorization_context: "operator")

    assert_equal "completed",
      SolidObjects.redrives.find(task.id, authorization_context: "operator").status
    assert_equal [ "redrive.start", "redrive.finish" ],
      SolidObjects::AdministrationEvent.order(:id).map(&:action)
  end

  test "refuses an unauthorized caller that reaches the manager directly" do
    SolidObjects.configuration.authorize_administration = ->(**) { false }

    assert_raises(SolidObjects::Unauthorized) do
      SolidObjects.redrives.start(
        scope: SolidObjects.dead_letters.effects,
        filters: { "actor_type" => nil, "failed_after" => nil, "limit" => nil },
        authorization_context: "operator"
      )
    end
  end

  test "refuses an unauthorized caller" do
    dead_effects(5)
    task = SolidObjects.dead_letters.effects.redrive(authorization_context: "operator")
    SolidObjects.configuration.authorize_administration = ->(**) { false }

    assert_raises(SolidObjects::Unauthorized) do
      SolidObjects.dead_letters.effects.redrive(authorization_context: "operator")
    end
    assert_raises(SolidObjects::Unauthorized) do
      task.cancel(authorization_context: "operator")
    end
    assert_raises(SolidObjects::Unauthorized) do
      SolidObjects.redrives.all(authorization_context: "operator")
    end
    assert_raises(SolidObjects::Unauthorized) do
      SolidObjects.redrives.find(task.id, authorization_context: "operator")
    end
  end

  test "a supervised runtime advances a redrive without a caller driving it" do
    dead_effects(12)
    SolidObjects.configuration.redrive_batch_size = 4
    supervisor = SolidObjects::Supervisor.new(
      worker_count: 0,
      effect_worker_count: 0,
      broadcast_worker_count: 0,
      reminder_scheduler_count: 1
    )
    task = SolidObjects.dead_letters.effects.redrive(authorization_context: "operator")

    supervisor.start
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    until SolidObjects.redrives.find(task.id, authorization_context: "operator").status == "completed"
      flunk "the supervisor did not finish the redrive" if
        Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.05
    end

    assert_equal 12, SolidObjects::Effect.where(status: "pending").count
  ensure
    supervisor&.stop
  end

  test "reports a task as a frozen value" do
    dead_effects(1)

    task = SolidObjects.dead_letters.effects.redrive(authorization_context: "operator")

    assert_kind_of SolidObjects::RedriveTask, task
    assert task.frozen?
    assert_equal "effect", task.kind
    assert task.started_at
    assert_nil task.finished_at
  end

  private

  def dead_effects(count)
    SolidObjects.register_effect(:settle) { raise "declined" }
    count.times { |index| PaymentActor.ref("order-#{index}").async.place(order: index) }
    run_actors
    SolidObjects::Effect.where.not(status: "dead").update_all(
      status: "dead", updated_at: SolidObjects.database_adapter.database_now
    )
    assert_equal count, SolidObjects::Effect.where(status: "dead").count
  end

  def dead_broadcast
    SolidObjects.configuration.broadcast_adapter = ->(_payload) { raise "transport down" }
    ShipmentActor.ref("one").async.touch
    run_actors
    SolidObjects::Broadcast.where.not(status: "dead").update_all(
      status: "dead", updated_at: SolidObjects.database_adapter.database_now
    )
  end

  def drain
    runner = SolidObjects::RedriveRunner.new
    nil while runner.run_once
  end

  def run_actors
    worker = SolidObjects::Worker.new
    worker.run_until_idle
  ensure
    worker&.stop
  end
end
