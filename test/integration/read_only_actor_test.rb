# frozen_string_literal: true

require "database_test_helper"

class ReadOnlyActorTest < ActiveSupport::TestCase
  class Reader < SolidObjects::Actor
    actor_type "read-only-reader"
    attribute :items, default: []

    class << self
      attr_accessor :projection_action
    end

    query :read do |action:|
      perform_action(action)
      items
    end

    observable :projected do
      perform_action(self.class.projection_action) if self.class.projection_action
      items
    end

    def append
      items << "committed"
      items
    end

    private

    def perform_action(action)
      case action
      when "effect" then emit :unexpected
      when "recovery" then request_effect_recovery("effect_id" => "missing-effect")
      when "commit_action" then commit_action :unexpected
      when "reminder" then schedule(at: Time.now + 60).append
      when "outbound" then send_to(self.class.ref("other")).append
      when "state" then items << "unexpected"
      end
    end
  end

  setup do
    Reader.projection_action = nil
    SolidObjects.configuration.max_attempts = 3
    SolidObjects.configuration.retry_delay = ->(_) { 0 }
    SolidObjects.register_commit_action(:unexpected) { SolidObjectsTestDomainRecord.create!(name: "unexpected") }
  end

  %w[effect recovery commit_action reminder outbound state].each do |action|
    test "queries reject #{action} without committing or retrying" do
      error = assert_raises(SolidObjects::MessageFailed) { Reader.ref("one").sync.read(action:) }

      assert_equal "SolidObjects::QueryMutatedState", error.details.fetch("class")
      assert_no_committed_work
    end

    test "observables reject #{action} without committing or retrying" do
      Reader.projection_action = action

      error = assert_raises(SolidObjects::MessageFailed) { Reader.ref("one").sync.append }

      assert_equal "SolidObjects::QueryMutatedState", error.details.fetch("class")
      assert_no_committed_work
    end
  end

  test "individual snapshot projections cannot mutate state" do
    Reader.projection_action = "state"
    snapshot = SolidObjects::ActorSnapshot.new(Reader.ref("snapshot"))

    error = assert_raises(SolidObjects::Error) { snapshot.observable_value(:projected) }

    assert_equal "SolidObjects::QueryMutatedState", error.class.name
    assert_empty SolidObjects::Instance.all
  end

  test "pure projections preserve effects already staged by an operation" do
    reader = Reader.new(actor_id: "local", state: SolidObjects::State.new(Reader.definition.state_definition))
    reader.emit(:expected)

    assert_equal({ "projected" => [] }, reader.observable_values)
    assert_equal "expected", reader.drain_effect_intents.sole.name
  end

  private

  def assert_no_committed_work
    assert_empty SolidObjects::Instance.find_by!(actor_id: "one").state
    assert_equal 1, SolidObjects::Message.sole.attempt_count
    assert_empty SolidObjects::Effect.all
    assert_empty SolidObjects::EffectRecovery.all
    assert_empty SolidObjects::Reminder.all
    assert_empty SolidObjects::Broadcast.all
    assert_empty SolidObjectsTestDomainRecord.all
  end
end
