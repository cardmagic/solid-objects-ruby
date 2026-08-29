# rbs_inline: enabled

module SolidObjects
  module Serialization
    MAX_NESTING = 100

    Dumped = Data.define(:value, :byte_size)

    class << self
      # @rbs (untyped, ?max_bytes: Integer?) -> untyped
      def dump(value, max_bytes: nil)
        return normalize(value) unless max_bytes

        dump_with_byte_size(value, max_bytes:).value
      end

      # @rbs (untyped, ?max_bytes: Integer?) -> Dumped
      def dump_with_byte_size(value, max_bytes: nil)
        normalized = normalize(value)
        byte_size = JSON.generate(normalized, max_nesting: MAX_NESTING).bytesize

        if max_bytes && byte_size > max_bytes
          raise PayloadTooLarge, "serialized value exceeds #{max_bytes} bytes"
        end

        Dumped.new(value: normalized, byte_size:)
      rescue JSON::GeneratorError, EncodingError => error
        raise InvalidPayload, error.message
      end

      # @rbs (untyped) -> untyped
      def load(value)
        return nil if value.nil?

        normalize(value)
      end

      # @rbs (untyped) -> untyped
      def deep_copy(value)
        JSON.parse(JSON.generate(normalize(value), max_nesting: MAX_NESTING))
      rescue JSON::GeneratorError, JSON::ParserError, EncodingError => error
        raise InvalidPayload, error.message
      end

      # @rbs (untyped) -> untyped
      def readonly_copy(value)
        freeze_recursively(deep_copy(value))
      end

      private

      # @rbs (untyped) -> untyped
      def freeze_recursively(value)
        case value
        when Array
          value.each { |item| freeze_recursively(item) }
        when Hash
          value.each do |key, item|
            freeze_recursively(key)
            freeze_recursively(item)
          end
        end

        value.freeze
      end

      # @rbs (untyped, ?depth: Integer) -> untyped
      def normalize(value, depth: 0)
        raise InvalidPayload, "serialized value is nested too deeply" if depth > MAX_NESTING

        case value
        when nil, true, false, Integer
          value
        when String
          raise InvalidPayload, "strings must hold valid #{value.encoding} bytes" unless value.valid_encoding?

          value
        when Float
          raise InvalidPayload, "non-finite numbers are not supported" unless value.finite?

          value
        when Symbol
          value.to_s
        when Array
          value.map { |item| normalize(item, depth: depth + 1) }
        when Hash
          normalize_hash(value, depth:)
        else
          raise InvalidPayload, "#{value.class} is not JSON-compatible"
        end
      end

      # @rbs (Hash[untyped, untyped], depth: Integer) -> Hash[String, untyped]
      def normalize_hash(value, depth:)
        value.each_with_object({}) do |(key, item), normalized|
          normalized_key = normalize_key(key)
          raise InvalidPayload, "duplicate key after normalization: #{normalized_key}" if normalized.key?(normalized_key)

          normalized[normalized_key] = normalize(item, depth: depth + 1)
        end
      end

      # @rbs (untyped) -> String
      def normalize_key(key)
        return normalize(key) if key.is_a?(String)
        return key.to_s if key.is_a?(Symbol)

        raise InvalidPayload, "JSON object keys must be strings or symbols"
      end
    end
  end
end
