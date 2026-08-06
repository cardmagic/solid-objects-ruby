# frozen_string_literal: true

require "database_test_helper"

class SupervisorTest < ActiveSupport::TestCase
  test "registers every process kind and stops them gracefully" do
    supervisor = SolidObjects::Supervisor.new(
      worker_count: 1,
      effect_worker_count: 1,
      broadcast_worker_count: 1,
      reminder_scheduler_count: 1
    )

    supervisor.start

    assert_equal(
      %w[broadcast effect reminder worker],
      SolidObjects::Process.order(:kind).pluck(:kind)
    )

    supervisor.stop

    assert_equal [ "stopped" ], SolidObjects::Process.distinct.pluck(:shutdown_state)
    assert SolidObjects::Process.all.all?(&:stopped_at)
  ensure
    supervisor&.stop
  end
end
