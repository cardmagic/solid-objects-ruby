# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require_relative "../../examples/at_least_once/sink"

class AtLeastOnceSinkTest < ActiveSupport::TestCase
  test "records every delivery when deduplication is off" do
    Dir.mktmpdir do |directory|
      path = File.join(directory, "sink.json")

      first = AtLeastOnceSink.record(path:, effect_id: "effect-1", attempt: 1, deduplication: :off)
      second = AtLeastOnceSink.record(path:, effect_id: "effect-1", attempt: 2, deduplication: :off)

      assert first
      assert second
      assert_equal(
        [
          { "effect_id" => "effect-1", "attempt" => 1 },
          { "effect_id" => "effect-1", "attempt" => 2 }
        ],
        AtLeastOnceSink.read(path)
      )
    end
  end

  test "applies a replayed effect id once when deduplication is on" do
    Dir.mktmpdir do |directory|
      path = File.join(directory, "sink.json")

      first = AtLeastOnceSink.record(path:, effect_id: "effect-1", attempt: 1, deduplication: :on)
      replay = AtLeastOnceSink.record(path:, effect_id: "effect-1", attempt: 2, deduplication: :on)

      assert first
      refute replay
      assert_equal([ { "effect_id" => "effect-1", "attempt" => 1 } ], AtLeastOnceSink.read(path))
    end
  end

  test "reads an empty sink where no file exists" do
    Dir.mktmpdir do |directory|
      assert_equal [], AtLeastOnceSink.read(File.join(directory, "missing.json"))
    end
  end
end
