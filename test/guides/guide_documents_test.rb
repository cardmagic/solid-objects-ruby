# frozen_string_literal: true

require "test_helper"

class GuideDocumentsTest < ActiveSupport::TestCase
  ROOT = File.expand_path("../..", __dir__)
  GUIDES = {
    "docs/guides/race-conditions.md" => [
      "examples/guides/race_conditions/event.rb",
      "examples/guides/race_conditions/event_tickets.rb"
    ],
    "docs/guides/ordered-jobs.md" => [
      "examples/guides/ordered_jobs/account.rb",
      "examples/guides/ordered_jobs/apply_entry_unordered_job.rb",
      "examples/guides/ordered_jobs/apply_entry_job.rb",
      "examples/guides/ordered_jobs/create_ledger_entries.rb",
      "examples/guides/ordered_jobs/solid_objects.rb",
      "examples/guides/ordered_jobs/ledger_account.rb"
    ],
    "docs/guides/expiring-reservations.md" => [
      "examples/guides/expiring_reservations/seat_inventory.rb"
    ],
    "docs/guides/transactional-outbox.md" => [
      "examples/guides/transactional_outbox/order.rb",
      "examples/guides/transactional_outbox/shipment_job.rb",
      "examples/guides/transactional_outbox/outbox_message.rb",
      "examples/guides/transactional_outbox/checkout.rb",
      "examples/guides/transactional_outbox/solid_objects.rb"
    ]
  }.freeze
  DASHES = [ "–", "—" ].freeze
  LINK = /(?<!!)\[[^\]]*\]\(([^)\s]+)\)/

  GUIDES.each do |guide, examples|
    test "#{guide} embeds each tested example file verbatim" do
      source = File.read(File.join(ROOT, guide))

      examples.each do |example|
        code = File.read(File.join(ROOT, example)).delete_prefix("# rbs_inline: enabled\n\n")
        assert_includes source, "```ruby\n#{code}```", "#{guide} does not embed the current #{example}"
      end
    end

    test "#{guide} uses no em dash or en dash" do
      source = File.read(File.join(ROOT, guide))

      DASHES.each do |dash|
        refute_includes source, dash, "#{guide} contains #{dash.unpack1("U").to_s(16)}"
      end
    end

    test "#{guide} links only to files that exist" do
      prose = File.read(File.join(ROOT, guide)).gsub(/^```.*?^```$/m, "")

      prose.scan(LINK).flatten.each do |link|
        next if link.start_with?("http://", "https://", "mailto:", "#")

        target = File.expand_path(link.split("#").first, File.dirname(File.join(ROOT, guide)))
        assert File.exist?(target), "#{guide} links to missing #{link}"
      end
    end
  end

  test "the README and the agent guide list every guide" do
    readme = File.read(File.join(ROOT, "README.md"))
    agents = File.read(File.join(ROOT, "docs/agents.md"))

    GUIDES.each_key do |guide|
      assert_includes readme, "(#{guide})"
      assert_includes agents, "(#{guide.delete_prefix("docs/")})"
    end
  end
end
