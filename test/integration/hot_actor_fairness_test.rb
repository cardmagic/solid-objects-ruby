# frozen_string_literal: true

require "database_test_helper"

class HotActorFairnessTest < ActiveSupport::TestCase
  class FairActor < SolidObjects::Actor
    actor_type "fair-actor"

    class << self
      attr_accessor :processed
    end

    def run(label:)
      self.class.processed << [ actor_id, label ]
    end
  end

  setup do
    FairActor.processed = []
    SolidObjects.configuration.max_messages_per_activation_pass = 1
  end

  test "releases a hot actor at the pass limit so another actor runs next" do
    hot = FairActor.ref("hot")
    cold = FairActor.ref("cold")
    hot.async(:run, label: 1)
    hot.async(:run, label: 2)
    cold.async(:run, label: 3)
    worker = SolidObjects::Worker.new

    worker.run_once
    worker.run_once

    assert_equal [ [ "hot", 1 ], [ "cold", 3 ] ], FairActor.processed
  ensure
    worker&.stop
  end
end
