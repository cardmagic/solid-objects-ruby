# rbs_inline: enabled

require "fileutils"
require "open3"
require "rubygems/package"
require "rubygems/installer"

module PackagedTypeCheck
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

  def typecheck_installed(project, package)
    gem_directory = File.join(project, "gems")
    specification = Gem::Installer.at(package, install_dir: gem_directory, ignore_dependencies: true).install
    script = <<~RUBY
      gem "solid_objects", #{"= #{SolidObjects::VERSION}".inspect}
      resolved = Gem.loaded_specs.fetch("solid_objects").full_gem_path
      abort "loaded signatures outside the built gem: \#{resolved}" unless resolved == #{specification.full_gem_path.inspect}
      load ARGV.shift
    RUBY
    output, error_output, status = Open3.capture3(
      {
        "RUBYOPT" => nil, "BUNDLE_GEMFILE" => nil,
        "GEM_HOME" => gem_directory, "GEM_PATH" => ([ gem_directory ] + Gem.path).join(File::PATH_SEPARATOR)
      },
      Gem.ruby, "-e", script, Gem.bin_path("steep", "steep"), "check", "--no-daemon", "-j", "1",
      chdir: project
    )
    [ output + error_output, status ]
  end

  def root_path(path)
    File.expand_path("../#{path}", __dir__)
  end
end
