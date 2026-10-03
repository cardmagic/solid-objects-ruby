# frozen_string_literal: true

require "database_test_helper"

class JsonCompatibilityTest < ActiveSupport::TestCase
  FIXTURES = JSON.parse(File.read(File.expand_path("../../compatibility/json-values.json", __dir__))).freeze

  class JsonActor < SolidObjects::Actor
    actor_type "json-compatibility"

    attribute :payload, default: -> { {} }

    def store(payload:)
      self.payload = payload
      payload
    end
  end

  test "preserves reserved keys through actor arguments, state, and results" do
    reference = JsonActor.ref("one")
    worker = SolidObjects::Worker.new

    FIXTURES.each do |fixture|
      value = fixture.fetch("value")
      message = reference.async(idempotency_key: fixture.fetch("name")).store(payload: value)
      worker.run_until_idle

      assert_equal value, message.result
      assert_equal value, reference.snapshot.payload
    end
  ensure
    worker&.stop
  end
end
