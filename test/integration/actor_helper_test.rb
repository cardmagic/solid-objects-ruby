# frozen_string_literal: true

require "database_test_helper"
require "action_view/test_case"
require "action_view/testing/resolvers"
require "cgi/escape"
require_relative "../../app/helpers/solid_objects/actor_helper"

class ActorHelperTest < ActionView::TestCase
  tests SolidObjects::ActorHelper

  class CartActor < SolidObjects::Actor
    actor_type "helper-cart"

    attribute :items, default: -> { [] }
    attribute :status, default: "open"

    observable :items_count, broadcast: :value do
      items.length
    end

    observable :items
    observable :status
    observable :private_status do
      status
    end

    def replace_items(items:)
      self.items = items
    end

    def close
      self.status = "closed"
    end
  end

  setup do
    SolidObjects.configuration.stream_signing_secret = "test-stream-signing-secret"
    SolidObjects.configuration.component_path_resolver = lambda do |view_context:|
      "/solid_objects/components"
    end
    CartActor.ensure_registered!
    @controller.prepend_view_path(
      ActionView::FixtureResolver.new(
        "actors/actor_helper_test/cart_actor/_items.html.erb" => <<~ERB,
          <ul>
            <% actor.items.each do |item| %>
              <li><%= item.fetch("name") %></li>
            <% end %>
          </ul>
        ERB
        "actors/actor_helper_test/cart_actor/_status.html.erb" => <<~ERB,
          <% if actor.status == "closed" %>
            <p>Closed</p>
          <% else %>
            <p>Open</p>
          <% end %>
        ERB
        "actors/actor_helper_test/cart_actor/_summary.html.erb" => <<~ERB,
          <p><%= actor.items.length %> items</p>
        ERB
        "actors/actor_helper_test/cart_actor/_player.html.erb" => <<~ERB,
          <article data-player-id="<%= player_id %>" data-component-key="<%= component_key %>">
            <%= label %>: <%= actor.status %>
          </article>
        ERB
        "actors/actor_helper_test/cart_actor/_leaky.html.erb" => <<~ERB
          <p><%= actor.status %></p>
        ERB
      )
    )
  end

  test "renders initial observable values with one actor subscription" do
    reference = CartActor.ref("alice")

    html = solid_object(reference) do |actor|
      safe_join([ actor.items_count, actor.items_count ])
    end

    assert_equal 1, html.scan("<turbo-cable-stream-source").length
    assert_equal 2, html.scan(">0</span>").length
    assert_includes html, %(channel="SolidObjects::ActorChannel")
    assert_includes html, %(id="#{SolidObjects::DomIdentity.scope(reference)}")
    refute_includes html, reference.actor_id
    assert_includes html, "data-token="
    assert_nil html[/<turbo-cable-stream-source[^>]*\stoken="/]

    token = html[/data-token="([^"]+)"/, 1]
    identity = SolidObjects::StreamToken.verify(token)
    assert_equal [ "items_count" ], identity.fetch("observables")
  end

  test "observables default to invalidation-only scalar targets" do
    reference = CartActor.ref("alice")

    error = assert_raises(ArgumentError) do
      solid_object(reference) { |actor| actor.private_status }
    end
    assert_includes error.message, "invalidation-only"
  end

  test "authorizes initial actor state reads" do
    SolidObjects.configuration.authorize_query = ->(**) { false }

    assert_raises(SolidObjects::Unauthorized) do
      solid_object(CartActor.ref("alice")) { |actor| actor.items_count }
    end
  end

  test "does not expose the old actor scope helper" do
    assert_not respond_to?(:actor_scope, true)
  end

  test "renders collection components as ordinary ERB values" do
    reference = CartActor.ref("alice")
    reference.replace_items(
      items: [
        { name: "<First>" },
        { name: "Second" }
      ]
    )

    html = solid_object(reference, authorization_context: "alice") do |actor|
      actor.component(:items, observes: :items)
    end

    assert_includes html, "<turbo-frame"
    assert_includes html, "<li>&lt;First&gt;</li>"
    assert_includes html, "<li>Second</li>"
    refute_includes html, JSON.generate(reference.snapshot.items)
    assert_includes html, "data-components="
    assert_includes html, "data-token="
    assert_nil html[/<turbo-cable-stream-source[^>]*\stoken="/]

    token = html[/data-token="([^"]+)"/, 1]
    identity = SolidObjects::StreamToken.verify(token)
    assert_empty identity.fetch("observables")
  end

  test "renders conditional components from declared dependencies" do
    reference = CartActor.ref("alice")

    open_html = solid_object(reference) do |actor|
      actor.component(:status, observes: :status)
    end
    reference.close
    closed_html = solid_object(reference) do |actor|
      actor.component(:status, observes: :status)
    end

    assert_includes open_html, "<p>Open</p>"
    assert_includes closed_html, "<p>Closed</p>"
  end

  test "rejects unknown component dependencies" do
    error = assert_raises(SolidObjects::UnknownComponentDependency) do
      solid_object(CartActor.ref("alice")) do |actor|
        actor.component(:items, observes: :private_items)
      end
    end

    assert_match(/private_items/, error.message)
  end

  test "rejects arbitrary partial paths for reactive components" do
    assert_raises(ArgumentError) do
      solid_object(CartActor.ref("alice")) do |actor|
        actor.component(
          :items,
          observes: :items,
          partial: "../../secrets"
        )
      end
    end
  end

  test "authorizes initial component rendering with the view context" do
    authorization_calls = []
    SolidObjects.configuration.authorize_query = lambda do |**arguments|
      authorization_calls << arguments
      arguments.fetch(:authorization_context) == "alice"
    end

    html = solid_object(
      CartActor.ref("alice"),
      authorization_context: "alice"
    ) do |actor|
      actor.component(:items, observes: :items)
    end

    assert_includes html, "<turbo-frame"
    assert_equal "items", authorization_calls.sole.fetch(:operation)

    assert_raises(SolidObjects::Unauthorized) do
      solid_object(
        CartActor.ref("alice"),
        authorization_context: "mallory"
      ) do |actor|
        actor.component(:items, observes: :items)
      end
    end
  end

  test "authorizes a reactive component name before its dependencies" do
    authorization_calls = []
    SolidObjects.configuration.authorize_query = lambda do |**arguments|
      authorization_calls << arguments
      arguments.fetch(:operation) == "items"
    end

    assert_raises(SolidObjects::Unauthorized) do
      solid_object(
        CartActor.ref("alice"),
        authorization_context: "alice"
      ) do |actor|
        actor.component(:summary, observes: :items)
      end
    end

    assert_equal [ "summary" ],
      authorization_calls.map { |arguments| arguments.fetch(:operation) }
  end

  test "rejects observable reads omitted from component dependencies" do
    error = assert_raises(SolidObjects::UnknownComponentDependency) do
      solid_object(CartActor.ref("alice")) do |actor|
        actor.component(:leaky, observes: :items)
      end
    end

    assert_match(/status/, error.message)
  end

  test "renders repeatable keyed components with signed locals" do
    reference = CartActor.ref("alice")

    html = solid_object(reference) do |actor|
      safe_join(
        [
          actor.component(
            :player,
            key: "alice",
            observes: :status,
            locals: { player_id: "alice", label: "You" }
          ),
          actor.component(
            :player,
            key: "bob",
            observes: :status,
            locals: { player_id: "bob", label: "Opponent" }
          )
        ]
      )
    end

    assert_includes html, %(data-player-id="alice")
    assert_includes html, %(data-component-key="alice")
    assert_includes html, "You: open"
    assert_includes html, %(data-player-id="bob")
    assert_includes html, "Opponent: open"

    registrations = component_registrations(html)
    assert_equal %w[alice bob], registrations.map(&:component_key)
    assert_equal(
      [
        { "player_id" => "alice", "label" => "You" },
        { "player_id" => "bob", "label" => "Opponent" }
      ],
      registrations.map(&:locals)
    )
    assert_equal 2, registrations.map(&:dom_id).uniq.length
  end

  test "rejects duplicate component names and keys within one scope" do
    error = assert_raises(ArgumentError) do
      solid_object(CartActor.ref("alice")) do |actor|
        safe_join(
          [
            actor.component(:status, key: "alice", observes: :status),
            actor.component(:status, key: "alice", observes: :status)
          ]
        )
      end
    end

    assert_match(/already rendered/, error.message)
  end

  test "rejects unsafe reactive component locals" do
    invalid_locals = [
      [ { actor: "shadowed" }, SolidObjects::InvalidComponentToken ],
      [ { authorization_context: "shadowed" }, SolidObjects::InvalidComponentToken ],
      [ { component_key: "shadowed" }, SolidObjects::InvalidComponentToken ],
      [ { "invalid-name" => "value" }, SolidObjects::InvalidComponentToken ],
      [ { class: "value" }, SolidObjects::InvalidComponentToken ],
      [ { callback: Object.new }, SolidObjects::InvalidPayload ]
    ]
    invalid_locals.each do |locals, error_class|
      assert_raises(error_class) do
        solid_object(CartActor.ref("alice")) do |actor|
          actor.component(
            :player,
            key: "alice",
            observes: :status,
            locals:
          )
        end
      end
    end
  end

  test "loads the morph refresh client only for morph components" do
    reference = CartActor.ref("alice")

    replace_html = solid_object(reference) do |actor|
      actor.component(:status, observes: :status)
    end
    morph_html = solid_object(reference) do |actor|
      actor.component(:status, observes: :status, refresh: :morph)
    end

    refute_includes replace_html, "solid_objects/component_refresh"
    assert_includes morph_html, "solid_objects/component_refresh"
    assert_includes morph_html, %(data-solid-objects-refresh="morph")
    assert_equal "morph", component_registrations(morph_html).sole.refresh_method
  end

  private

  def component_registrations(html)
    serialized = CGI.unescapeHTML(html[/data-components="([^"]+)"/, 1])
    JSON.parse(serialized).map do |token|
      SolidObjects::ComponentRegistration.from_token(token)
    end
  end
end
