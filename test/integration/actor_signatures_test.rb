# rbs_inline: enabled

require "test_helper"
require "tmpdir"
require "fileutils"
require "open3"
require "rubygems/package"
require_relative "../types/actor_operations"

class ActorSignaturesTest < ActiveSupport::TestCase
  test "generates checked actor-specific signatures without changing dispatch" do
    require "solid_objects/actor_signatures"
    signatures = SolidObjects::ActorSignatures.generate(
      actors: [ SignatureChat ], signatures: [ fixture_path("actor_operations.rbs") ]
    )
    assert_equal signatures, SolidObjects::ActorSignatures.generate(
      actors: [ SignatureChat ], signatures: [ fixture_path("actor_operations.rbs") ]
    )
    assert_includes signatures, "recover_if_stuck"
    refute_includes signatures, "def helper:"
    refute_includes signatures, "def status:"

    Dir.mktmpdir("solid-objects-actor-signatures") do |directory|
      assert_packaged_generator(directory, signatures)
      FileUtils.mkdir_p(File.join(directory, "sig"))
      FileUtils.cp(fixture_path("actor_operations.rbs"), File.join(directory, "sig/actors.rbs"))
      File.write(File.join(directory, "sig/generated.rbs"), signatures)
      consumer_path = File.join(directory, "consumer.rb")
      consumer = File.read(fixture_path("actor_operations.rb"))
      File.write(consumer_path, consumer)
      File.write(File.join(directory, "Steepfile"), <<~RUBY)
        target :consumer do
          library "solid_objects"
          signature "sig"
          check "consumer.rb"
          configure_code_diagnostics(Diagnostic::Ruby.strict)
        end
      RUBY
      output, status = typecheck(directory)
      assert status.success?, output

      generated_path = File.join(directory, "sig/generated.rbs")
      File.write(generated_path, "")
      output, status = typecheck(directory)
      refute status.success?, output
      assert_includes output, "Ruby::NoMethod"
      assert_includes output, "recover_if_stuck"
      File.write(generated_path, signatures)

      invalid_calls = <<~RUBY
        schedule(at: Time.now).recover_if_stcuk(generation: 1)
        schedule(at: Time.now).recover_if_stuck
        schedule(at: Time.now).recover_if_stuck(generation: "wrong")
        schedule(at: Time.now).recover_if_stuck(generation: 1, extra: true)
        transmit.recover_if_stcuk(generation: 1)
        transmit.recover_if_stuck(generation: "wrong")
        schedule(at: Time.now).helper
        schedule(at: Time.now).status
        schedule(at: Time.now).generation
        emit :run_model, on_failure: :fail_trun
        emit :run_model, on_success: "finsih"
        emit :run_model, on_failure: :helper
        emit :run_model, on_success: :status
        emit :run_model, on_failure: :schedule
        emit :build_report, on_recovery: :recvoer
        emit :build_report, on_status: :inspec
      RUBY
      File.write(consumer_path, consumer.sub("    commit_action :global_action, generation: 1", invalid_calls))
      output, status = typecheck(directory)
      refute status.success?, output
      invalid_calls.lines.each do |line|
        assert_includes output, line.strip
      end
    end
  end

  test "requires explicit compatible application signatures" do
    require "solid_objects/actor_signatures"
    original = File.read(fixture_path("actor_operations.rbs"))
    [
      original.sub("  def recover_if_stuck: (generation: Integer) -> Integer\n", ""),
      original.sub("(generation: Integer) -> Integer", "(Integer) -> Integer"),
      original.sub("(generation: Integer) -> Integer", "(generation: Integer) { () -> void } -> Integer"),
      original.sub("class SignatureChat <", "class SignatureChat[Value] <")
    ].each do |invalid|
      Dir.mktmpdir("solid-objects-invalid-signatures") do |directory|
        path = File.join(directory, "actors.rbs")
        File.write(path, invalid)
        assert_raises(ArgumentError) do
          SolidObjects::ActorSignatures.generate(actors: [ SignatureChat ], signatures: [ path ])
        end
      end
    end
  end

  test "refreshes removed operations and orders actors deterministically" do
    require "solid_objects/actor_signatures"
    arguments = { signatures: [ fixture_path("actor_operations.rbs") ] }
    assert_equal SolidObjects::ActorSignatures.generate(actors: [ SignatureParent, SignatureChat ], **arguments),
      SolidObjects::ActorSignatures.generate(actors: [ SignatureChat, SignatureParent ], **arguments)

    original_method = SignatureChat.instance_method(:optional)
    SignatureChat.remove_method(:optional)
    regenerated = SolidObjects::ActorSignatures.generate(actors: [ SignatureChat ], **arguments)
    refute_includes regenerated, "def optional:"
    refute_includes regenerated, ":optional"
  ensure
    SignatureChat.define_method(:optional, original_method) if original_method
  end

  private

  def assert_packaged_generator(directory, expected)
    artifact = File.join(directory, "solid_objects.gem")
    specification = Gem::Specification.load(File.expand_path("../../solid_objects.gemspec", __dir__))
    Gem::DefaultUserInteraction.use_ui(Gem::SilentUI.new) do
      Gem::Package.build(specification, false, false, artifact)
    end
    package = File.join(directory, "package")
    Gem::Package.new(artifact).extract_files(package)
    script = <<~RUBY
      require #{File.join(package, "lib/solid_objects/actor_signatures.rb").inspect}
      require #{fixture_path("actor_operations.rb").inspect}
      print SolidObjects::ActorSignatures.generate(
        actors: [SignatureChat], signatures: [#{fixture_path("actor_operations.rbs").inspect}]
      )
    RUBY
    output, errors, status = Open3.capture3(Gem.ruby, "-e", script)
    assert status.success?, errors
    assert_equal expected, output
  end

  def fixture_path(name)
    File.expand_path("../types/#{name}", __dir__)
  end

  def typecheck(directory)
    output, errors, status = Open3.capture3(
      Gem.ruby, Gem.bin_path("steep", "steep"), "check", "--no-daemon", "-j", "1", chdir: directory
    )
    [ output + errors, status ]
  end
end
