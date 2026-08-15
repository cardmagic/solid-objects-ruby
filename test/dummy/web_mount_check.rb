# frozen_string_literal: true

# A Rack application behaves differently under a real Rails router than under a
# mock environment: the mount supplies SCRIPT_NAME, the session middleware
# supplies the session CSRF protection needs, and a nested mount depends on the
# engine cascading paths it does not serve. None of that is exercised by
# calling the dashboard directly, so this runs it where it actually runs.

ENV["RAILS_ENV"] = "test"

require_relative "config/environment"
require "solid_objects/web"
require "rack/mock_request"
require_relative "../../db/migrate/20260805000000_create_solid_objects_tables"
require_relative "../../db/migrate/20260806000000_add_state_revision_to_solid_objects_instances"
require_relative "../../db/migrate/20260813000000_rename_message_dispatch_columns"

ActiveRecord::Migration.verbose = false
CreateSolidObjectsTables.new.migrate(:up)
AddStateRevisionToSolidObjectsInstances.new.migrate(:up)
RenameMessageDispatchColumns.new.migrate(:up)

instance = SolidObjects::Instance.create!(
  actor_type: "MountCheckActor",
  actor_id: "only-one",
  state: { "value" => 7 }
)

Rails.application.routes.draw do
  mount SolidObjects::Engine => "/solid_objects"
  mount SolidObjects::Web => "/solid_objects/dashboard"
end

request = Rack::MockRequest.new(Rails.application)

SolidObjects.configuration.authorize_administration = ->(**) { false }
denied = request.get("https://example.com/solid_objects/dashboard/instances")

SolidObjects.configuration.authorize_administration = ->(**) { true }
allowed = request.get("https://example.com/solid_objects/dashboard/instances")

detail_path = "https://example.com/solid_objects/dashboard/instances/#{instance.id}"
detail = request.get(detail_path)
cookie = detail.headers["set-cookie"].to_s.split(";").first.to_s
token = detail.body[/name="authenticity_token" value="([^"]+)"/, 1].to_s

def pause(request, path, cookie, token)
  options = { params: { "authenticity_token" => token } }
  options["HTTP_COOKIE"] = cookie
  request.post("#{path}/pause", options)
end

# Well formed and the right length, so it reaches the comparison rather than
# being turned away by the length check on the way in.
forged = pause(request, detail_path, cookie, SecureRandom.base64(32))
forged_paused = instance.reload.paused_at

paused = pause(request, detail_path, cookie, token)

puts "denied=#{denied.status}"
puts "allowed=#{allowed.status}"
puts "actor=#{allowed.body.include?("MountCheckActor")}"
puts "mounted_link=#{allowed.body.include?("/solid_objects/dashboard/stylesheets/application.css")}"
puts "session=#{allowed.headers["set-cookie"].to_s.include?("_dummy_session")}"
puts "forged=#{forged.status}"
puts "forged_paused=#{!forged_paused.nil?}"
puts "paused=#{paused.status}"
puts "paused_location=#{paused.headers["location"]}"
puts "paused_at=#{!instance.reload.paused_at.nil?}"
