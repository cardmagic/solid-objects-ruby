# frozen_string_literal: true

require "test_helper"

class InstrumentationTest < ActiveSupport::TestCase
  class RecordingLogger
    attr_reader :entries

    def initialize
      @entries = []
    end

    def info(entry)
      entries << entry
    end
  end

  test "writes structured events without actor arguments" do
    logger = RecordingLogger.new
    SolidObjects.configuration.logger = logger
    SolidObjects::LogSubscriber.install

    SolidObjects.instrument(
      :"message.enqueued",
      message_id: 1,
      actor_type: "CartActor",
      actor_id: "alice"
    )

    entry = logger.entries.last
    assert_equal "solid_objects.message.enqueued", entry.fetch(:event)
    assert_equal 1, entry.fetch(:message_id)
    assert_not entry.key?(:arguments)
    assert entry.key?(:duration_ms)
  ensure
    SolidObjects::LogSubscriber.uninstall
  end
end
