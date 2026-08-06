# frozen_string_literal: true

require "test_helper"

class CommitActionRegistryTest < ActiveSupport::TestCase
  test "registers handlers by normalized name" do
    registry = SolidObjects::CommitActionRegistry.new
    handler = Object.new.method(:itself).to_proc

    registry.register(:persist_attempt, handler)

    assert_same handler, registry.fetch("persist_attempt")
  end

  test "rejects missing handlers without retry" do
    registry = SolidObjects::CommitActionRegistry.new

    assert_raises(SolidObjects::UnknownCommitAction) do
      registry.fetch(:missing)
    end
  end
end
