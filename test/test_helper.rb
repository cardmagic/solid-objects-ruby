# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"

require "minitest"
require "active_support/testing/autorun"
require "solid_objects"

class ActiveSupport::TestCase
  setup do
    SolidObjects.reset!
    SolidObjects.configuration.authorize_message = ->(**) { true }
    SolidObjects.configuration.authorize_query = ->(**) { true }
  end
end
