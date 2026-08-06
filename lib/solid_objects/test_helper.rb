# rbs_inline: enabled

require "solid_objects"

module SolidObjects
  module TestHelper
    class << self
      # @rbs (Class) -> void
      def included(test_case)
        test_case.use_transactional_tests = false if test_case.respond_to?(:use_transactional_tests=)
        test_case.setup { reset_actors! }
        test_case.teardown { reset_actors! }
      end

      # @rbs () -> void
      def reset_actors!
        SolidObjects.reset_caller_process!
        Instance.delete_all
        Process.delete_all
      end
    end

    # @rbs () -> void
    def reset_actors!
      TestHelper.reset_actors!
    end

    # @rbs (?roles: Array[Symbol], ?max_passes: Integer) -> Integer
    def drain_solid_objects(
      roles: [ :reminders, :actors, :effects, :broadcasts ],
      max_passes: 1_000
    )
      runners = build_solid_objects_runners(roles)
      total = 0

      max_passes.times do
        processed = runners.sum { |runner| solid_objects_runner_result(runner) }
        break if processed.zero?

        total += processed
      end

      total
    ensure
      runners&.uniq&.each(&:stop)
    end

    private

    # @rbs (Array[Symbol]) -> Array[Worker | EffectExecutor | ReminderScheduler | BroadcastExecutor]
    def build_solid_objects_runners(roles)
      unknown_roles = roles - [ :actors, :effects, :reminders, :broadcasts ]
      raise ArgumentError, "unknown Solid Objects test roles: #{unknown_roles.join(", ")}" if unknown_roles.any?

      runners = {}
      runners[:actors] = Worker.new if roles.include?(:actors)
      runners[:effects] = EffectExecutor.new if roles.include?(:effects)
      runners[:reminders] = ReminderScheduler.new if roles.include?(:reminders)
      runners[:broadcasts] = BroadcastExecutor.new if roles.include?(:broadcasts)

      [
        runners[:reminders],
        runners[:actors],
        runners[:effects],
        runners[:actors],
        runners[:broadcasts]
      ].compact
    end

    # @rbs (Worker | EffectExecutor | ReminderScheduler | BroadcastExecutor) -> Integer
    def solid_objects_runner_result(runner)
      result = runner.run_once
      return result if result.is_a?(Integer)

      result ? 1 : 0
    end
  end
end
