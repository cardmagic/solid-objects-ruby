# frozen_string_literal: true

require "web_test_helper"

class WebChartsTest < WebTestCase
  teardown do
    SolidObjects::Web.reset!
  end

  test "loads the chart library from the configured source with an integrity hash" do
    response = get("/")

    assert_match(%r{src="https://cdn\.jsdelivr\.net/npm/chart\.js@[\d.]+/dist/chart\.umd\.min\.js"}, response.body)
    assert_match(/integrity="sha384-[A-Za-z0-9+\/=]+"/, response.body)
    assert_match(/crossorigin="anonymous"/, response.body)
  end

  test "names the chart host in the content security policy and nothing wider" do
    policy = get("/").headers["content-security-policy"]
    script_source = policy[/script-src ([^;]+)/, 1]

    assert_includes script_source, "https://cdn.jsdelivr.net"
    refute_includes script_source, "'unsafe-inline'"
    refute_includes script_source, "'unsafe-eval'"
    # The host, not the scheme. A bare `https:` source would admit every host
    # that serves over TLS.
    refute_match(/(\A|\s)https:(\s|\z)/, script_source)
  end

  test "renders the instance counts each chart draws" do
    2.times { |index| create_instance(actor_type: "web-counter", actor_id: "counter-#{index}") }
    create_instance(actor_type: "web-room", actor_id: "room")

    values = chart_values(get("/").body, "instances_by_type")

    assert_equal({ "web-counter" => 2, "web-room" => 1 }, values)
  end

  test "renders mailbox and outbox charts from the same counts the page shows" do
    instance = create_instance
    mark_ready(create_message(instance))
    body = get("/").body

    assert_equal({ "Ready" => 1, "Due" => 1, "Claimed" => 0 }, chart_values(body, "mailbox_depth"))

    statuses = chart_values(body, "work_by_status")

    assert_equal 0, statuses.dig("Effects", "pending")
    assert_equal 0, statuses.dig("Broadcasts", "delivered")
    assert_equal 0, statuses.dig("Reminders", "scheduled")
  end

  test "escapes an actor type that would otherwise close the data attribute" do
    create_instance(actor_type: "web-'onerror=alert(1)", actor_id: "one")
    body = get("/").body

    # The quote is what matters: escaped, the payload stays one attribute
    # value; raw, it would close the attribute and start a new one.
    assert_includes body, "&#39;onerror"
    refute_includes body, "'onerror"
    assert_equal({ "web-'onerror=alert(1)" => 1 }, chart_values(body, "instances_by_type"))
  end

  test "serves no chart library and names no external host when charts are disabled" do
    SolidObjects::Web.chart_library_url = nil

    response = get("/")

    refute_match(/jsdelivr/, response.body)
    refute_match(/data-chart=/, response.body)
    refute_includes response.headers["content-security-policy"], "jsdelivr"
  end

  test "accepts a self hosted copy without widening the policy" do
    SolidObjects::Web.chart_library_url = "/javascripts/chart.js"
    SolidObjects::Web.chart_library_integrity = nil

    response = get("/")
    script_source = response.headers["content-security-policy"][/script-src ([^;]+)/, 1]

    assert_match(%r{src="/solid_objects/javascripts/chart\.js"}, response.body)
    refute_match(/integrity=/, response.body)
    refute_match(%r{https?://}, script_source)
  end

  test "leaves list pages without a chart library" do
    refute_match(/jsdelivr/, get("/instances").body)
  end

  # Chart.js sizes a responsive canvas from its parent. Left in a panel whose
  # own height follows its children, each redraw measures a box that the last
  # redraw resized, and the chart creeps larger on every poll. The library
  # requires a dedicated container with a height of its own.
  test "puts every canvas in a container with a height that does not follow it" do
    body = get("/").body

    canvases = body.scan("<canvas data-chart=").length
    framed = body.scan(%r{<div class="chart-frame"><canvas data-chart=}).length

    assert_equal 3, canvases
    assert_equal canvases, framed, "every canvas needs its own sized container"
  end

  test "sizes the chart container in the stylesheet and takes the canvas out of flow" do
    stylesheet = File.read(File.expand_path("../../web/assets/stylesheets/application.css", __dir__))
    frame = stylesheet[/\.chart-frame \{([^}]*)\}/, 1].to_s
    canvas = stylesheet[/\.chart-frame canvas \{([^}]*)\}/, 1].to_s

    assert_match(/position:\s*relative/, frame)
    assert_match(/height:\s*\d+px/, frame)
    # Out of flow, the canvas cannot change the height of the box the library
    # measures, so no redraw can feed the next one.
    assert_match(/position:\s*absolute/, canvas)
    refute_match(/canvas\s*\{[^}]*height[^}]*!important/, stylesheet,
      "forcing the canvas height fights the library instead of sizing its container")
  end

  private

  def chart_values(body, name)
    raw = body[/data-chart="#{name}" data-chart-values='([^']*)'/, 1]
    assert raw, "no chart named #{name} in the page"

    JSON.parse(CGI.unescapeHTML(raw))
  end
end
