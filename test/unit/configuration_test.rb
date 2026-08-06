# frozen_string_literal: true

require "test_helper"

class ConfigurationTest < ActiveSupport::TestCase
  test "denies every externally initiated operation by default" do
    configuration = SolidObjects::Configuration.new

    refute configuration.authorize_message.call
    refute configuration.authorize_query.call
    refute configuration.authorize_subscription.call
    refute configuration.authorize_administration.call
  end
end
