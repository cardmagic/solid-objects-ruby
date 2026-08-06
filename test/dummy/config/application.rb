# frozen_string_literal: true

require_relative "boot"

require "rails"
require "active_record/railtie"
require "action_controller/railtie"
require "action_view/railtie"
require "action_cable/engine"
require "action_view/base"
require "solid_objects"

Bundler.require(*Rails.groups)

module Dummy
  class Application < Rails::Application
    config.root = File.expand_path("..", __dir__)
    config.load_defaults Rails::VERSION::STRING.to_f
    config.eager_load = false
    config.secret_key_base = "solid-objects-test-secret-key-base"
    config.logger = Logger.new(nil)
  end
end
