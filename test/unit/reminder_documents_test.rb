# frozen_string_literal: true

require "test_helper"

class ReminderDocumentsTest < ActiveSupport::TestCase
  ROOT = File.expand_path("../..", __dir__)
  REMINDER_METHODS = %i[schedule unschedule unschedule_all reminder reminders].freeze

  def guide(path)
    File.read(File.join(ROOT, path))
  end

  test "the reminder guide names each public reminder method of an actor" do
    REMINDER_METHODS.each do |method|
      assert SolidObjects::Actor.public_method_defined?(method), "SolidObjects::Actor has no public #{method}"
      assert_includes guide("docs/reminders.md"), "`#{method}`", "docs/reminders.md does not name #{method}"
    end
  end

  test "the reminder guide does not deny a method that an actor has" do
    refute_match(/has no `unschedule`/, guide("docs/reminders.md"))
  end

  test "the agent guide shows how to cancel a reminder" do
    assert_includes guide("docs/agents.md"), "unschedule(:expire, key: buyer)"
  end
end
