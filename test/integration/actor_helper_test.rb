# frozen_string_literal: true

require "database_test_helper"
require "action_view/test_case"
require_relative "../../app/helpers/solid_objects/actor_helper"

class ActorHelperTest < ActionView::TestCase
  tests SolidObjects::ActorHelper

  class CartActor < SolidObjects::Actor
    actor_type "helper-cart"

    attribute :items, default: -> { [] }

    observable :items_count do
      state.items.length
    end
  end

  setup do
    SolidObjects.configuration.stream_signing_secret = "test-stream-signing-secret"
    CartActor.ensure_registered!
  end

  test "renders initial observable values with one actor subscription" do
    reference = CartActor.ref("alice")

    html = actor_scope(reference) do |actor|
      safe_join([ actor.items_count, actor.items_count ])
    end

    assert_equal 1, html.scan("<turbo-cable-stream-source").length
    assert_equal 2, html.scan(">0</span>").length
    assert_includes html, %(channel="SolidObjects::ActorChannel")
    assert_includes html, %(id="#{SolidObjects::DomIdentity.scope(reference)}")
    refute_includes html, reference.actor_id
  end

  test "authorizes initial actor state reads" do
    SolidObjects.configuration.authorize_query = ->(**) { false }

    assert_raises(SolidObjects::Unauthorized) do
      actor_scope(CartActor.ref("alice")) { |actor| actor.value(:items_count) }
    end
  end
end
