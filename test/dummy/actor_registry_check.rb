# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"

require_relative "config/environment"

# A lazily loading web process. Nothing here names the actor class, the way
# nothing in a freshly booted Passenger worker names it until some request
# happens to render or address that actor.
puts SolidObjects.registry.registered?("CliWorkerActor") ? "registered" : "unregistered"
