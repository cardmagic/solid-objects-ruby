# frozen_string_literal: true

require "test_helper"

class ConfigurationTest < ActiveSupport::TestCase
  test "denies every externally initiated operation by default" do
    configuration = SolidObjects::Configuration.new

    refute configuration.authorize_message.call
    refute configuration.authorize_query.call
    refute configuration.authorize_destroy.call
    refute configuration.authorize_subscription.call
    refute configuration.authorize_administration.call
  end

  test "provides conservative retention defaults" do
    configuration = SolidObjects::Configuration.new

    assert_equal 30.days, configuration.message_retention
    assert_equal({}, configuration.message_retention_by_actor_type)
    assert_equal({}, configuration.instance_retention_by_actor_type)
    assert_equal 7.days, configuration.process_retention
    assert_equal 1_000, configuration.prune_batch_size
  end

  test "uses the refresh controller as the default component authorization context" do
    configuration = SolidObjects::Configuration.new
    controller = Object.new

    assert_same controller,
      configuration.component_authorization_context.call(controller:)
  end

  test "rejects invalid actor retention overrides" do
    configuration = SolidObjects::Configuration.new
    configuration.message_retention_by_actor_type = { "Counter" => 0.days }

    error = assert_raises(ArgumentError) { configuration.validate! }

    assert_equal "message retention must be positive", error.message
  end

  test "rejects invalid instance retention policies" do
    configuration = SolidObjects::Configuration.new
    configuration.instance_retention_by_actor_type = { "Counter" => 0.days }

    error = assert_raises(ArgumentError) { configuration.validate! }

    assert_equal "instance retention must be positive", error.message
  end

  test "warns about large state well below the hard state limit" do
    configuration = SolidObjects::Configuration.new

    assert_equal 64.kilobytes, configuration.warn_state_bytes
    assert_operator configuration.warn_state_bytes, :<, configuration.max_state_bytes
  end

  test "rejects a soft state threshold above the hard state limit" do
    configuration = SolidObjects::Configuration.new
    configuration.warn_state_bytes = configuration.max_state_bytes + 1

    error = assert_raises(ArgumentError) { configuration.validate! }

    assert_equal "warn_state_bytes must not exceed max_state_bytes", error.message
  end

  test "rejects a non-positive state size warning threshold" do
    configuration = SolidObjects::Configuration.new
    configuration.warn_state_bytes = 0

    error = assert_raises(ArgumentError) { configuration.validate! }

    assert_equal "warn_state_bytes must be positive", error.message
  end

  test "rejects a non-positive idle polling interval" do
    configuration = SolidObjects::Configuration.new
    configuration.idle_polling_interval = 0

    error = assert_raises(ArgumentError) { configuration.validate! }

    assert_equal "idle_polling_interval must be positive", error.message
  end
end
