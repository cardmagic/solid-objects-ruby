# frozen_string_literal: true

require "web_test_helper"

class WebTest < WebTestCase
  test "denies every page when administration is not authorized" do
    SolidObjects.configuration.authorize_administration = ->(**) { false }

    %w[/ /instances /mailbox /reminders /effects /broadcasts /dead_letters /processes /stats].each do |path|
      response = get(path)

      assert_equal 403, response.status, "#{path} must deny by default"
    end
  end

  test "denies with the default configuration, which authorizes nothing" do
    SolidObjects.reset!

    assert_equal 403, get("/").status
  end

  test "passes the route policy and the request to the authorization block" do
    instance = create_instance
    seen = []
    SolidObjects.configuration.authorize_administration = lambda do |action:, resource:, resource_id:, authorization_context:|
      seen << [ action, resource, resource_id, authorization_context.request.path ]
      true
    end

    get("/instances/#{instance.id}")

    assert_equal [ [ "show", "instances", instance.id.to_s, "/solid_objects/instances/#{instance.id}" ] ], seen
  end

  test "renders the dashboard with runtime counts" do
    instance = create_instance
    mark_ready(create_message(instance))

    response = get("/")

    assert_equal 200, response.status
    assert_match(/Solid Objects/, response.body)
    assert_match(/Instances/, response.body)
    assert_match(/Ready/, response.body)
  end

  test "reports the same counts as JSON" do
    instance = create_instance
    mark_ready(create_message(instance))

    response = get("/stats")
    payload = JSON.parse(response.body)

    assert_equal 200, response.status
    assert_equal "application/json", response.headers["content-type"]
    assert_equal "private, no-store", response.headers["cache-control"]
    assert_equal 1, payload.dig("instances", "total")
    assert_equal 1, payload.dig("mailbox", "ready")
    assert_equal 0, payload.dig("mailbox", "claimed")
  end

  test "answers a HEAD request without rendering a page" do
    response = request("/", method: "HEAD", params: {})

    assert_equal 200, response.status
    assert_empty response.body
  end

  test "lists instances and links to each one" do
    instance = create_instance(actor_type: "web-counter", actor_id: "alpha")

    response = get("/instances")

    assert_equal 200, response.status
    assert_match(/web-counter/, response.body)
    assert_match(/alpha/, response.body)
    assert_match(%r{/solid_objects/instances/#{instance.id}}, response.body)
  end

  test "filters instances by actor type and by actor id substring" do
    create_instance(actor_type: "web-counter", actor_id: "alpha")
    create_instance(actor_type: "web-room", actor_id: "beta")

    typed = get("/instances", "actor_type" => "web-room")

    assert_match(/beta/, typed.body)
    refute_match(/alpha/, typed.body)

    named = get("/instances", "actor_id" => "alph")

    assert_match(/alpha/, named.body)
    refute_match(/beta/, named.body)
  end

  test "pages the instance list" do
    3.times { |index| create_instance(actor_id: "page-#{index}") }

    response = get("/instances", "per_page" => "2")

    assert_equal 2, response.body.scan("data-instance-row").length
    assert_match(/page=2/, response.body)
  end

  test "shows an instance with its state and mailbox" do
    instance = create_instance(state: { "value" => 41 })
    mark_ready(create_message(instance, operation: "increment"))

    response = get("/instances/#{instance.id}")

    assert_equal 200, response.status
    assert_match(/41/, response.body)
    assert_match(/increment/, response.body)
  end

  test "returns 404 for an unknown instance" do
    assert_equal 404, get("/instances/999999").status
  end

  test "renders an instance whose actor type is no longer registered" do
    instance = create_instance(actor_type: "web-retired-actor")

    response = get("/instances/#{instance.id}")

    assert_equal 200, response.status
    assert_match(/web-retired-actor/, response.body)
  end

  test "escapes actor identifiers in rendered pages" do
    create_instance(actor_id: "<script>alert(1)</script>")

    response = get("/instances")

    refute_match(%r{<script>alert}, response.body)
    assert_match(/&lt;script&gt;alert/, response.body)
  end

  test "pauses and resumes an instance" do
    instance = create_instance

    paused = post("/instances/#{instance.id}/pause")

    assert_equal 302, paused.status
    assert instance.reload.paused_at

    resumed = post("/instances/#{instance.id}/resume")

    assert_equal 302, resumed.status
    assert_nil instance.reload.paused_at
  end

  test "rejects a state changing request without a valid CSRF token" do
    instance = create_instance

    response = post_without_csrf_token("/instances/#{instance.id}/pause")

    assert_equal 403, response.status
    assert_nil instance.reload.paused_at
  end

  test "lists ready and claimed mailbox messages" do
    instance = create_instance
    mark_ready(create_message(instance, operation: "increment"))

    response = get("/mailbox")

    assert_equal 200, response.status
    assert_match(/increment/, response.body)
    assert_match(/ready/, response.body)
  end

  test "shows a single message with its arguments" do
    instance = create_instance
    message = create_message(instance, operation: "increment")

    response = get("/messages/#{message.id}")

    assert_equal 200, response.status
    assert_match(/increment/, response.body)
    assert_match(/amount/, response.body)
  end

  test "lists reminders, effects, broadcasts and processes" do
    instance = create_instance
    message = create_message(instance)
    now = SolidObjects.database_adapter.database_now
    SolidObjects::Reminder.create!(
      instance:,
      actor_type: instance.actor_type,
      actor_id: instance.actor_id,
      name: "web-reminder",
      operation: "tick",
      arguments: {},
      next_run_at: now
    )
    SolidObjects::Effect.create!(
      instance:,
      message:,
      effect_id: SecureRandom.uuid,
      name: "web-effect",
      arguments: {},
      max_attempts: 5,
      available_at: now
    )
    SolidObjects::Broadcast.create!(
      instance:,
      message:,
      broadcast_id: SecureRandom.uuid,
      observable_name: "web-observable",
      value: {},
      state_version: 1,
      activation_generation: 1,
      available_at: now
    )
    SolidObjects::Process.create!(
      id: SecureRandom.uuid,
      kind: "worker",
      hostname: "web-host",
      pid: 4321,
      started_at: now,
      last_heartbeat_at: now,
      metadata: {}
    )

    assert_match(/web-reminder/, get("/reminders").body)
    assert_match(/web-effect/, get("/effects").body)
    assert_match(/web-observable/, get("/broadcasts").body)
    assert_match(/web-host/, get("/processes").body)
  end

  test "filters a status backed list" do
    instance = create_instance
    message = create_message(instance)
    now = SolidObjects.database_adapter.database_now
    SolidObjects::Effect.create!(
      instance:,
      message:,
      effect_id: SecureRandom.uuid,
      name: "web-pending-effect",
      arguments: {},
      max_attempts: 5,
      available_at: now
    )

    assert_match(/web-pending-effect/, get("/effects", "status" => "pending").body)
    refute_match(/web-pending-effect/, get("/effects", "status" => "dead").body)
  end

  test "serves the stylesheet and the javascript from the mount" do
    stylesheet = get("/stylesheets/application.css")
    javascript = get("/javascripts/application.js")

    assert_equal 200, stylesheet.status
    assert_equal 200, javascript.status
  end

  test "builds asset and page links below the mount path" do
    response = get("/")

    assert_match(%r{href="/solid_objects/stylesheets/application.css"}, response.body)
    assert_match(%r{href="/solid_objects/instances"}, response.body)
  end

  test "sends a nonce backed content security policy" do
    response = get("/")
    nonce = response.body[/nonce="([^"]+)"/, 1]

    assert nonce
    assert_includes response.headers["content-security-policy"], "'nonce-#{nonce}'"
    refute_includes response.headers["content-security-policy"],
      SolidObjects::Web::Application::SCRIPT_PLACEHOLDER
    assert_equal "nosniff", response.headers["x-content-type-options"]
  end

  test "returns 404 with a cascade header for an unknown path" do
    response = get("/nowhere")

    assert_equal 404, response.status
    assert_equal "pass", response.headers["x-cascade"]
  end
end
