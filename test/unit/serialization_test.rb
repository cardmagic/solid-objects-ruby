# frozen_string_literal: true

require "test_helper"

class SerializationTest < ActiveSupport::TestCase
  test "normalizes symbol keys and nested values" do
    value = SolidObjects::Serialization.dump({
      product_id: "shirt",
      details: { quantity: 2 },
      tags: [ :sale ]
    })

    assert_equal(
      {
        "product_id" => "shirt",
        "details" => { "quantity" => 2 },
        "tags" => [ "sale" ]
      },
      value
    )
  end

  test "rejects duplicate keys after normalization" do
    assert_raises(SolidObjects::InvalidPayload) do
      SolidObjects::Serialization.dump({ "status" => "open", :status => "closed" })
    end
  end

  test "rejects non-finite numbers" do
    assert_raises(SolidObjects::InvalidPayload) do
      SolidObjects::Serialization.dump(Float::INFINITY)
    end
  end

  test "rejects arbitrary objects even when they define as_json" do
    value = Class.new do
      def as_json
        { safe: "looking" }
      end
    end.new

    assert_raises(SolidObjects::InvalidPayload) do
      SolidObjects::Serialization.dump(value)
    end
  end

  test "enforces the encoded byte limit" do
    assert_raises(SolidObjects::PayloadTooLarge) do
      SolidObjects::Serialization.dump("four", max_bytes: 5)
    end
  end

  test "returns an independent deep copy" do
    original = { "items" => [ { "quantity" => 1 } ] }
    copy = SolidObjects::Serialization.deep_copy(original)

    copy.fetch("items").first["quantity"] = 2

    assert_equal 1, original.fetch("items").first.fetch("quantity")
  end

  test "returns a deeply frozen read-only copy" do
    original = { "items" => [ { "quantity" => 1 } ] }
    copy = SolidObjects::Serialization.readonly_copy(original)

    assert_predicate copy, :frozen?
    assert_predicate copy.fetch("items"), :frozen?
    assert_predicate copy.fetch("items").first, :frozen?
    assert_raises(FrozenError) { copy.fetch("items").first["quantity"] = 2 }
  end
end
