# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"
ENV["SOLID_OBJECTS_DUMMY_CONNECTS_TO"] = "1"

require_relative "config/environment"

Rails.application.eager_load!

puts ActiveRecord::Base.connection_handler.connection_pool_names.sort.join(" ")
