# rbs_inline: enabled

require "rack/request"
require "rack/utils"
require "securerandom"

module SolidObjects
  class Web
    # A state changing request must carry the token of the session that asked
    # for the form. The token a form receives is masked with a fresh one-time
    # pad on every request, so the bytes on the wire differ each time and a
    # compression side channel cannot recover the session token.
    class CsrfProtection
      SAFE_METHODS = %w[GET HEAD OPTIONS TRACE].freeze
      TOKEN_BYTES = 32

      MISSING_SESSION = <<~MESSAGE
        SolidObjects::Web needs a Rack session for CSRF protection.

        Mount it inside the application routes so the Rails session middleware runs first:

          Rails.application.routes.draw do
            mount SolidObjects::Web => "/solid_objects"
          end

        In a bare Rack application, run a session middleware before it:

          use Rack::Session::Cookie, secret: ENV.fetch("SESSION_SECRET"), same_site: true
          run SolidObjects::Web
      MESSAGE

      # @rbs (untyped) -> void
      def initialize(app)
        @app = app
      end

      # @rbs (Hash[String, untyped]) -> Array[untyped]
      def call(env)
        return forbidden unless accept?(env)

        session = session!(env)
        session[:csrf] ||= SecureRandom.base64(TOKEN_BYTES)
        env[Web::CSRF_TOKEN_KEY] = mask(session[:csrf])
        @app.call(env)
      end

      private

      # @rbs (Hash[String, untyped]) -> bool
      def accept?(env)
        return true if SAFE_METHODS.include?(env["REQUEST_METHOD"])

        valid?(env, ::Rack::Request.new(env).params["authenticity_token"])
      end

      # @rbs (Hash[String, untyped], String?) -> bool
      def valid?(env, given)
        return false if given.nil? || given.empty?

        session = session!(env)
        stored = session[:csrf]
        return false if stored.nil?

        token = decode(given)
        return false unless token

        # The secret is not rotated here. A page renders one Retry form per
        # dead letter, and a browser keeps pages open in other tabs, so
        # spending the secret on the first submission would answer 403 to
        # every other form already rendered. Single use is not what a CSRF
        # token provides: it proves the request came from a page this session
        # was served, and the per-request mask below is what keeps the value
        # on the wire from repeating.
        matches?(token, stored)
      end

      # @rbs (String, String) -> bool
      def matches?(token, stored)
        candidate = case token.bytesize
        when TOKEN_BYTES then token
        when TOKEN_BYTES * 2 then unmask(token)
        else return false
        end

        ::Rack::Utils.secure_compare(candidate, decode(stored).to_s)
      end

      # @rbs (String) -> String
      def mask(token)
        decoded = decode(token).to_s
        pad = SecureRandom.random_bytes(decoded.bytesize)
        encode(pad + exclusive_or(pad, decoded))
      end

      # @rbs (String) -> String
      def unmask(masked)
        half = masked.bytesize / 2
        exclusive_or(masked[0, half].to_s, masked[half..].to_s)
      end

      # @rbs (String, String) -> String
      def exclusive_or(left, right)
        left.bytes.zip(right.bytes).map { |first, second| first ^ second.to_i }.pack("c*")
      end

      # @rbs (String) -> String
      def encode(token)
        [ token ].pack("m0").tr("+/", "-_")
      end

      # @rbs (String) -> String?
      def decode(token)
        decoded = token.tr("-_", "+/").unpack1("m0")
        decoded.is_a?(String) ? decoded : nil
      rescue ArgumentError
        nil
      end

      # @rbs (Hash[String, untyped]) -> Hash[untyped, untyped]
      def session!(env)
        env["rack.session"] || raise(MISSING_SESSION)
      end

      # @rbs () -> Array[untyped]
      def forbidden
        [ 403, { "content-type" => "text/plain" }, [ "Forbidden" ] ]
      end
    end
  end
end
