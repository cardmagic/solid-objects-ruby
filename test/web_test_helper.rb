# frozen_string_literal: true

require "database_test_helper"
require "rack/mock_request"
require "solid_objects/web"

# The dashboard is a Rack application rather than an engine controller, so the
# suite drives it the way a mount does: a real environment through the real
# middleware stack. Nothing here stubs the router, the session, or the
# authorization policy.
class WebTestCase < ActiveSupport::TestCase
  MOUNT_PATH = "/solid_objects"

  setup do
    SolidObjects.configuration.authorize_administration = ->(**) { true }
    @session = {}
  end

  teardown do
    SolidObjects::DeadLetter.delete_all
    SolidObjects::Broadcast.delete_all
    SolidObjects::Effect.delete_all
    SolidObjects::Reminder.delete_all
    SolidObjects::ClaimedMessage.delete_all
    SolidObjects::ReadyMessage.delete_all
    SolidObjects::Message.delete_all
  end

  private

  attr_reader :session

  # @rbs (String, ?Hash[String, untyped]) -> Rack::MockResponse
  def get(path, params = {})
    request(path, method: "GET", params:)
  end

  # @rbs (String, ?Hash[String, untyped]) -> Rack::MockResponse
  def post(path, params = {})
    request(path, method: "POST", params: params.merge("authenticity_token" => csrf_token))
  end

  # @rbs (String, ?Hash[String, untyped]) -> Rack::MockResponse
  def post_without_csrf_token(path, params = {})
    request(path, method: "POST", params:)
  end

  # @rbs (String, method: String, params: Hash[String, untyped]) -> Rack::MockResponse
  def request(path, method:, params:)
    environment = Rack::MockRequest.env_for(
      "http://example.com#{MOUNT_PATH}#{path}",
      method:,
      params:
    )
    environment["SCRIPT_NAME"] = MOUNT_PATH
    environment["PATH_INFO"] = path
    environment["rack.session"] = session
    status, headers, body = SolidObjects::Web.call(environment)
    Rack::MockResponse.new(status, headers, body)
  end

  # The middleware issues a fresh masked token per request, and accepts the
  # unmasked session value too. Reading the session directly keeps the helper
  # from parsing HTML for a token every form-driven test needs.
  # @rbs () -> String
  def csrf_token
    get("/") if session[:csrf].nil?
    session.fetch(:csrf)
  end

  # @rbs (?actor_type: String, ?actor_id: String, ?state: Hash[String, untyped]) -> SolidObjects::Instance
  def create_instance(actor_type: "web-counter", actor_id: "one", state: { "value" => 1 })
    SolidObjects::Instance.create!(actor_type:, actor_id:, state:)
  end

  # @rbs (SolidObjects::Instance, ?operation: String, ?delivery_mode: String) -> SolidObjects::Message
  def create_message(instance, operation: "increment", delivery_mode: "async")
    now = SolidObjects.database_adapter.database_now
    sequence = instance.next_message_sequence
    instance.update!(next_message_sequence: sequence + 1)
    SolidObjects::Message.create!(
      instance:,
      actor_type: instance.actor_type,
      actor_id: instance.actor_id,
      operation:,
      delivery_mode:,
      arguments: { "amount" => 1 },
      sequence:,
      max_attempts: 5,
      request_id: SecureRandom.uuid,
      enqueued_at: now,
      available_at: now
    )
  end

  # @rbs (SolidObjects::Message) -> SolidObjects::ReadyMessage
  def mark_ready(message)
    SolidObjects::ReadyMessage.create!(
      message:,
      instance_id: message.instance_id,
      sequence: message.sequence,
      available_at: message.available_at,
      created_at: message.enqueued_at
    )
  end
end
