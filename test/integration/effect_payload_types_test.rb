# rbs_inline: enabled

require "test_helper"
require "fileutils"
require "open3"
require "tmpdir"
require "rubygems/package"

class EffectPayloadTypesTest < ActiveSupport::TestCase
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

      [
        [ '"effect_id" => "effect-1"', '"effect_identifier" => "effect-1"' ],
        [ '"message" => "failed"', '"message" => 42' ],
        [ 'arguments["generation"]', 'arguments["generation"].to_s' ]
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
        [ '"backtrace" => Array(exception.backtrace).first(50)', '"backtrace" => [42]' ]
      ].each do |original, invalid|
        File.write(constructor_path, constructors.sub(original, invalid))
        output, status = typecheck(project)
        refute status.success?, "invalid constructor escaped the compiler: #{invalid}"
        assert_includes output, "Ruby::MethodBodyTypeMismatch"
      end
    end
  end

  private

  def build_package(directory)
    artifact = File.join(directory, "solid_objects.gem")
    specification = Gem::Specification.load(root_path("solid_objects.gemspec"))
    Gem::DefaultUserInteraction.use_ui(Gem::SilentUI.new) do
      Gem::Package.build(specification, false, false, artifact)
    end
    artifact
  end

  def typecheck(project)
    output, error_output, status = Open3.capture3(
      Gem.ruby, Gem.bin_path("steep", "steep"), "check", "--no-daemon", "-j", "1",
      chdir: project
    )
    [ output + error_output, status ]
  end

  def root_path(path)
    File.expand_path("../../#{path}", __dir__)
  end
end
