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

  test "does not encode a value that has no byte limit" do
    assert_equal 0, json_generate_calls { SolidObjects::Serialization.dump({ quantity: 1 }) }
  end

  test "encodes once when it must enforce a byte limit" do
    assert_equal 1, json_generate_calls { SolidObjects::Serialization.dump({ quantity: 1 }, max_bytes: 1_024) }
  end

  test "rejects a value that is not JSON-compatible when it has no byte limit" do
    assert_raises(SolidObjects::InvalidPayload) do
      SolidObjects::Serialization.dump(Object.new)
    end
  end

  test "rejects a string that cannot be encoded when it has no byte limit" do
    assert_raises(SolidObjects::InvalidPayload) do
      SolidObjects::Serialization.dump(invalid_encoding_string)
    end
  end

  test "rejects a string that cannot be encoded inside a nested value" do
    assert_raises(SolidObjects::InvalidPayload) do
      SolidObjects::Serialization.dump({ "items" => [ { "note" => invalid_encoding_string } ] })
    end
  end

  test "rejects a key that cannot be encoded" do
    assert_raises(SolidObjects::InvalidPayload) do
      SolidObjects::Serialization.dump({ invalid_encoding_string => "value" })
    end
  end

  test "converts an encoding failure into an invalid payload" do
    assert_raises(SolidObjects::InvalidPayload) do
      SolidObjects::Serialization.dump(invalid_encoding_string, max_bytes: 1_024)
    end
  end

  test "reports the encoded byte size beside the normalized value" do
    dumped = SolidObjects::Serialization.dump_with_byte_size({ quantity: 1 }, max_bytes: 1_024)

    assert_equal({ "quantity" => 1 }, dumped.value)
    assert_equal 14, dumped.byte_size
  end

  test "enforces the encoded byte limit while it reports the byte size" do
    assert_raises(SolidObjects::PayloadTooLarge) do
      SolidObjects::Serialization.dump_with_byte_size("four", max_bytes: 5)
    end
  end

  test "reports the encoded byte size beside a deep copy" do
    copied = SolidObjects::Serialization.deep_copy_with_byte_size({ quantity: 1 })

    assert_equal({ "quantity" => 1 }, copied.value)
    assert_equal 14, copied.byte_size
  end

  test "copies independently while it reports the byte size" do
    original = { "items" => [ { "quantity" => 1 } ] }

    copied = SolidObjects::Serialization.deep_copy_with_byte_size(original)
    copied.value.fetch("items").first["quantity"] = 2

    assert_equal 1, original.fetch("items").first.fetch("quantity")
  end

  test "encodes a deep copy once" do
    assert_equal 1, json_generate_calls { SolidObjects::Serialization.deep_copy_with_byte_size({ quantity: 1 }) }
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

  private

  def json_generate_calls
    calls = 0
    trace = TracePoint.new(:call, :c_call) do |point|
      calls += 1 if point.method_id == :generate && point.self == JSON
    end
    trace.enable { yield }
    calls
  end

  def invalid_encoding_string
    (+"\xC3").force_encoding(Encoding::UTF_8)
  end
end
