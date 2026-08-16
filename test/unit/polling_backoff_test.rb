# frozen_string_literal: true

require "test_helper"
require "solid_objects/polling_backoff"

class PollingBackoffTest < ActiveSupport::TestCase
  test "doubles empty-poll intervals until the idle ceiling" do
    backoff = SolidObjects::PollingBackoff.new(
      minimum_interval: 0.025,
      maximum_interval: 1.0
    )

    intervals = [ backoff.current_interval ]
    7.times do
      backoff.record_idle
      intervals << backoff.current_interval
    end

    assert_equal [ 0.025, 0.05, 0.1, 0.2, 0.4, 0.8, 1.0, 1.0 ], intervals
  end

  test "resets to the fast interval after processed work" do
    transitions = []
    backoff = SolidObjects::PollingBackoff.new(
      minimum_interval: 0.025,
      maximum_interval: 1.0,
      on_change: ->(transition) { transitions << transition }
    )
    backoff.record_idle
    backoff.record_idle

    backoff.reset(:work)

    assert_equal 0.025, backoff.current_interval
    assert_equal({
      previous_interval: 0.1,
      current_interval: 0.025,
      reason: :work
    }, transitions.last)
  end

  test "resets to the fast interval after a wake-up" do
    backoff = SolidObjects::PollingBackoff.new(
      minimum_interval: 0.025,
      maximum_interval: 1.0
    )
    backoff.record_idle
    backoff.record_idle

    backoff.reset(:wake_up)

    assert_equal 0.025, backoff.current_interval
  end
end
