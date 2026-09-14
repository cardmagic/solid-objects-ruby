# rbs_inline: enabled

require "test_helper"

class EffectPayloadTest < ActiveSupport::TestCase
  test "retains original arguments and each JSON success result" do
    arguments = { "generation" => 2, "nested" => { "retained" => true } }

    [ nil, false, 42, "reply", [ "reply" ], { "reply" => "done" } ].each do |result|
      payload = SolidObjects::EffectPayload.success(effect_id: "effect-1", arguments:, result:)

      assert_equal({ "effect_id" => "effect-1", "arguments" => arguments, "result" => result }, payload)
    end
  end

  test "retains the Ruby error fields and original empty arguments" do
    error = RuntimeError.new("failed")
    error.set_backtrace([ "actor.rb:12" ])
    summary = SolidObjects::EffectPayload.error(error)

    assert_equal({ "class" => "RuntimeError", "message" => "failed", "backtrace" => [ "actor.rb:12" ] }, summary)
    assert_equal({ "effect_id" => "effect-1", "arguments" => {}, "error" => summary },
      SolidObjects::EffectPayload.failure(effect_id: "effect-1", arguments: {}, error: summary))
  end

  test "retains existing message and backtrace limits" do
    error = RuntimeError.new("x" * 9_000)
    error.set_backtrace(Array.new(60) { |index| "actor.rb:#{index}" })

    summary = SolidObjects::EffectPayload.error(error)

    assert_equal "x" * 8_192, summary.fetch("message")
    assert_equal Array.new(50) { |index| "actor.rb:#{index}" }, summary.fetch("backtrace")
  end

  test "retains anonymous error classes and empty messages and backtraces" do
    error = Class.new(StandardError).new("")

    assert_equal({ "class" => nil, "message" => "", "backtrace" => [] },
      SolidObjects::EffectPayload.error(error))
  end
end
