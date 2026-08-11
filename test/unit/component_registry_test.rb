# frozen_string_literal: true

require "test_helper"

class ComponentRegistryTest < ActiveSupport::TestCase
  class CountingComponent
    attr_reader :runs

    def initialize
      @runs = 0
      @stopped = false
    end

    def run
      @runs += 1
    end

    def request_shutdown
      @stopped = true
    end

    def stop
      @stopped = true
    end

    def stopped? = @stopped
  end

  setup do
    SolidObjects.reset!
  end

  teardown do
    SolidObjects.reset!
  end

  test "starts with no registered component" do
    assert_empty SolidObjects.configuration.additional_components
  end

  test "registers a component factory" do
    SolidObjects.configuration.register_component { CountingComponent.new }

    assert_equal 1, SolidObjects.configuration.additional_components.length
  end

  test "builds a separate instance for each supervisor" do
    SolidObjects.configuration.register_component { CountingComponent.new }

    first = SolidObjects.configuration.build_additional_components
    second = SolidObjects.configuration.build_additional_components

    assert_not_same first.first, second.first
  end

  test "builds the requested count of a component" do
    SolidObjects.configuration.register_component(count: 3) { CountingComponent.new }

    assert_equal 3, SolidObjects.configuration.build_additional_components.length
  end

  test "refuses a component without a run method" do
    error = assert_raises(ArgumentError) do
      SolidObjects.configuration.register_component { Object.new }
    end

    assert_match(/run/, error.message)
  end

  test "refuses a component without a request_shutdown method" do
    incomplete = Class.new do
      def run
      end
    end

    error = assert_raises(ArgumentError) do
      SolidObjects.configuration.register_component { incomplete.new }
    end

    assert_match(/request_shutdown/, error.message)
  end

  # The supervisor calls stopped? and stop while it shuts down. A component
  # that misses either one would hang the shutdown instead of failing here.
  test "refuses a component that cannot report or force a stop" do
    without_stopped = Class.new do
      def run
      end

      def request_shutdown
      end

      def stop
      end
    end

    error = assert_raises(ArgumentError) do
      SolidObjects.configuration.register_component { without_stopped.new }
    end

    assert_match(/stopped\?/, error.message)
  end

  test "refuses a count below one" do
    assert_raises(ArgumentError) do
      SolidObjects.configuration.register_component(count: 0) { CountingComponent.new }
    end
  end

  test "refuses a registration without a block" do
    assert_raises(ArgumentError) do
      SolidObjects.configuration.register_component
    end
  end

  test "reset clears the registrations" do
    SolidObjects.configuration.register_component { CountingComponent.new }
    SolidObjects.reset!

    assert_empty SolidObjects.configuration.additional_components
  end
end
