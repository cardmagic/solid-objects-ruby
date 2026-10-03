# rbs_inline: enabled

require "test_helper"
require "tmpdir"
require "packaged_type_check"

class EffectPayloadTypesTest < ActiveSupport::TestCase
  include PackagedTypeCheck

  test "packaged payload contracts check consumers and the actual constructors" do
    Dir.mktmpdir("solid-objects-effect-types") do |directory|
      package = build_package(directory)
      project = File.join(directory, "consumer")
      Gem::Package.new(package).extract_files(project)
      FileUtils.cp(root_path("test/types/effect_payloads.rbs"), File.join(project, "sig/consumer.rbs"))
      consumer_path = File.join(project, "consumer.rb")
      consumer = File.read(root_path("test/types/effect_payloads.rb"))
      File.write(consumer_path, consumer)
      File.write(File.join(project, "Steepfile"), <<~RUBY)
        target :consumer do
          signature "sig"
          check "consumer.rb"
          check "lib/solid_objects/effect_payload.rb"
          configure_code_diagnostics(Diagnostic::Ruby.strict)
        end
      RUBY

      output, status = typecheck(project)
      assert status.success?, output

      configuration_path = File.join(project, "Steepfile")
      configuration = File.read(configuration_path)
      File.write(configuration_path, configuration.sub('signature "sig"', "library \"solid_objects\"\n  signature \"sig/consumer.rbs\""))
      output, status = typecheck_installed(project, package)
      assert status.success?, output
      File.write(configuration_path, configuration)

      signature_path = File.join(project, "sig/consumer.rbs")
      signatures = File.read(signature_path)
      File.write(signature_path, signatures.sub("effect_completed_recovery_payload[report_arguments, String]", "effect_recovery_payload[report_arguments, String]"))
      output, status = typecheck(project)
      refute status.success?, "Steep narrowing changed; update the documented record-union limitation"
      assert_includes output, "Ruby::ReturnTypeMismatch"
      File.write(signature_path, signatures)

      [
        [ '"effect_id" => "effect-1"', '"effect_identifier" => "effect-1"' ],
        [ '"message" => "failed"', '"message" => 42' ],
        [ 'arguments["generation"]', 'arguments["generation"].to_s' ],
        [ "EffectRecoveryOutcome::RETIRED", "EffectRecoveryOutcome::PENDING" ],
        [ 'payload["arguments"]["revision"]', 'payload["arguments"]["revision"].to_s' ]
      ].each do |original, invalid|
        File.write(consumer_path, consumer.sub(original, invalid))
        output, status = typecheck(project)
        refute status.success?, "invalid consumer escaped the compiler: #{invalid}"
        assert_includes output, "Ruby::MethodBodyTypeMismatch"
      end
      File.write(consumer_path, consumer)

      constructor_path = File.join(project, "lib/solid_objects/effect_payload.rb")
      constructors = File.read(constructor_path)
      [
        [ '"result" => result', '"outcome" => result' ],
        [ '"error" => error', '"failure" => error' ],
        [ '"backtrace" => Array(exception.backtrace).first(50)', '"backtrace" => [42]' ],
        [ '"outcome" => EffectRecoveryOutcome::RETIRED', '"outcome" => "recovered"' ],
        [ '"outcome" => EffectRecoveryOutcome::COMPLETED, "result" => result', '"outcome" => EffectRecoveryOutcome::COMPLETED' ]
      ].each do |original, invalid|
        File.write(constructor_path, constructors.sub(original, invalid))
        output, status = typecheck(project)
        refute status.success?, "invalid constructor escaped the compiler: #{invalid}"
        assert_includes output, "Ruby::MethodBodyTypeMismatch"
      end
    end
  end
end
