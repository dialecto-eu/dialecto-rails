require "json"
require "openssl"
require_relative "../config"

module DialectoRails
  module InContext
    # Verifies the launch token Dialecto mints for an editor (spec-0025 §3) with no call to Dialecto:
    #
    #   token  = base64url(payload) "." base64url(signature)
    #   signed = "dialecto-live-edit-v1." base64url(payload)
    #
    # The signature is Ed25519 under the repo's key, and the purpose prefix keeps a signature made for another
    # purpose (a release manifest) from verifying here. Needs the openssl gem 3.0 or later (Ruby 3.2 ships
    # 3.1) on OpenSSL 1.1.1 or later. Pure: the caller passes the key, the site's origin and the time.
    module LaunchToken
      PREFIX = "dialecto-live-edit-v1.".freeze
      BASE64URL = /\A[A-Za-z0-9_-]*\z/

      Result = Struct.new(:claims, :reason) do
        def ok? = reason.nil?
      end

      module_function

      # `phase` is `:start` when the token first arrives (which also requires `start_by` not to have passed)
      # or `:session` for the cookie on later requests (only `exp` matters). `reason` is one of `:malformed`,
      # `:bad_signature`, `:expired`, `:late`, `:wrong_origin` and `:wrong_repo`.
      #
      # With `repo` ("owner/name") the token's repo claim must match it, ignoring case (`:wrong_repo`): a
      # cheap check against a key pasted from the wrong repo.
      def verify(token, public_key, origin, now, phase = :session, repo: nil)
        return failure(:malformed) unless token.is_a?(String) && public_key.is_a?(String) && public_key.bytesize == 32
        return failure(:malformed) unless origin.is_a?(String) && now.is_a?(Integer)

        payload_b64, signature_b64, extra = token.split(".", 3)
        return failure(:malformed) if payload_b64.nil? || signature_b64.nil? || extra

        signature = decode(signature_b64)
        return failure(:malformed) unless signature&.bytesize == 64
        return failure(:bad_signature) unless signed?(payload_b64, signature, public_key)

        claims = claims(payload_b64)
        return failure(:malformed) unless claims

        return failure(:expired) if now >= claims["exp"]
        return failure(:late) if phase == :start && now > claims["start_by"]
        return failure(:wrong_origin) unless Config.normalize_origin(claims["origin"]) == origin
        return failure(:wrong_repo) if repo && !(claims["repo"].is_a?(String) && claims["repo"].casecmp?(repo))

        Result.new(claims, nil)
      end

      def failure(reason) = Result.new(nil, reason)

      def decode(text)
        return nil unless text.match?(BASE64URL) && text.length % 4 != 1

        (text.tr("-_", "+/") + "=" * (-text.length % 4)).unpack1("m")
      end

      def signed?(payload_b64, signature, public_key)
        OpenSSL::PKey.new_raw_public_key("ED25519", public_key).verify(nil, signature, PREFIX + payload_b64)
      rescue OpenSSL::PKey::PKeyError
        false
      end

      def claims(payload_b64)
        json = decode(payload_b64)
        claims = json && JSON.parse(json.force_encoding(Encoding::UTF_8))
        valid = claims.is_a?(Hash) && claims["v"] == 1 && claims["origin"].is_a?(String) &&
          claims["exp"].is_a?(Integer) && claims["start_by"].is_a?(Integer)
        valid ? claims : nil
      rescue JSON::ParserError, EncodingError
        nil
      end
    end
  end
end
