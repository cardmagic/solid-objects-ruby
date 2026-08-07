# frozen_string_literal: true

require "test_helper"

class ActorRegistryTest < ActiveSupport::TestCase
  class RegisteredActor < SolidObjects::Actor
    actor_type "registered"
  end

  setup do
    SolidObjects.register_actor("registered", RegisteredActor)
  end

  test "registers and resolves an actor without constantizing persisted input" do
    assert_equal RegisteredActor, SolidObjects.registry.fetch("registered")
  end

  test "rejects another class for the same actor type" do
    other_actor = Class.new(SolidObjects::Actor)

    assert_raises(SolidObjects::InvalidActor) do
      SolidObjects.register_actor("registered", other_actor)
    end
  end

  test "replaces a reloaded actor class with the same name" do
    actor_name = "ReloadedRegistryActor"
    Object.const_set(actor_name, Class.new(SolidObjects::Actor))
    original_actor = Object.const_get(actor_name)
    SolidObjects.register_actor("reloadable", original_actor)
    Object.send(:remove_const, actor_name)
    Object.const_set(actor_name, Class.new(SolidObjects::Actor))
    reloaded_actor = Object.const_get(actor_name)

    SolidObjects.register_actor("reloadable", reloaded_actor)

    assert_equal reloaded_actor, SolidObjects.registry.fetch("reloadable")
  ensure
    Object.send(:remove_const, actor_name) if actor_name && Object.const_defined?(actor_name, false)
  end

  test "rejects distinct anonymous actors for the same actor type" do
    registry = SolidObjects::ActorRegistry.new
    registry.register("anonymous", Class.new(SolidObjects::Actor))

    assert_raises(SolidObjects::InvalidActor) do
      registry.register("anonymous", Class.new(SolidObjects::Actor))
    end
  end

  test "rejects classes that are not actors" do
    assert_raises(SolidObjects::InvalidActor) do
      SolidObjects.register_actor("not-an-actor", String)
    end
  end

  test "does not infer a class from an unknown type" do
    error = assert_raises(SolidObjects::UnknownActorType) do
      SolidObjects.registry.fetch("Kernel")
    end

    assert_match(/unknown actor type/, error.message)
  end
end
