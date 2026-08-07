# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"

require_relative "config/environment"

Rails.application.reload_routes!
puts SolidObjects::ComponentPathResolver.new.call(view_context: Object.new)
