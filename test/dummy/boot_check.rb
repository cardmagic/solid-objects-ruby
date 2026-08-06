# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"

require_relative "config/environment"

Rails.application.eager_load!

abort "engine is not isolated" unless SolidObjects::Engine.isolated?
abort "record is not loaded" unless SolidObjects::Record < ActiveRecord::Base

puts "solid_objects_dummy_booted"
