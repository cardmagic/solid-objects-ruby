# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"

require_relative "config/environment"

puts ActiveRecord::Encryption.config.primary_key
