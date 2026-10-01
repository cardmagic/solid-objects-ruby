# rbs_inline: enabled

require "test_helper"
require "tmpdir"
require "packaged_type_check"

class TelemetryTypesTest < ActiveSupport::TestCase
  include PackagedTypeCheck

  test "packaged telemetry contracts check event and diagnostic consumers" do
    Dir.mktmpdir("solid-objects-telemetry-types") do |directory|
      project = File.join(directory, "consumer")
      Gem::Package.new(build_package(directory)).extract_files(project)
      FileUtils.cp(root_path("test/types/telemetry.rbs"), File.join(project, "sig/consumer.rbs"))
      consumer_path = File.join(project, "consumer.rb")
      consumer = File.read(root_path("test/types/telemetry.rb"))
      File.write(consumer_path, consumer)
      File.write(File.join(project, "Steepfile"), <<~RUBY)
        target :consumer do
          signature "sig"
          check "consumer.rb"
          configure_code_diagnostics(Diagnostic::Ruby.strict)
        end
      RUBY

      output, status = typecheck(project)
      assert status.success?, output

      [
        [ 'event["name"]', 'event["attempt"]', "Ruby::MethodBodyTypeMismatch" ],
        [ 'event["attributes"]["waitingOn"]', 'event["attributes"]', "Ruby::MethodBodyTypeMismatch" ],
        [ 'metric["name"]', 'metric["value"]', "Ruby::BlockBodyTypeMismatch" ],
        [ 'summary["mailbox"]["oldestAgeMilliseconds"]', 'summary["mailbox"]["truncated"]', "Ruby::MethodBodyTypeMismatch" ],
        [ 'names << event["name"]', 'names << event["attempt"]', "Ruby::ArgumentTypeMismatch" ]
      ].each do |original, invalid, diagnostic|
        File.write(consumer_path, consumer.sub(original, invalid))
        output, status = typecheck(project)
        refute status.success?, "invalid consumer escaped the compiler: #{invalid}"
        assert_includes output, diagnostic
      end
    end
  end
end
