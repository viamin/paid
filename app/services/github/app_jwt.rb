# frozen_string_literal: true

require "base64"
require "openssl"

module Github
  class AppJwt
    class Error < StandardError; end
    class ConfigurationError < Error; end

    def self.sign(app_id:, private_key:)
      new(app_id: app_id, private_key: private_key).sign
    end

    def initialize(app_id:, private_key:)
      @app_id = app_id
      @private_key = private_key
    end

    def sign
      validate_configuration!

      segments = [
        jwt_segment(alg: "RS256", typ: "JWT"),
        jwt_segment(payload)
      ]

      signature = rsa_private_key.sign(OpenSSL::Digest::SHA256.new, segments.join("."))
      "#{segments.join(".")}.#{Base64.urlsafe_encode64(signature, padding: false)}"
    end

    def self.private_key_parseable?(key)
      return false if key.blank?

      OpenSSL::PKey::RSA.new(key.gsub('\n', "\n"))
      true
    rescue OpenSSL::PKey::RSAError
      false
    end

    private

    attr_reader :app_id, :private_key

    def validate_configuration!
      return if app_id.present? && private_key.present?

      raise ConfigurationError, "GitHub App ID and private key are required"
    end

    def payload
      now = Time.current.to_i
      {
        iat: now - 60,
        exp: now + (9 * 60),
        iss: app_id.to_s
      }
    end

    def jwt_segment(data)
      Base64.urlsafe_encode64(data.to_json, padding: false)
    end

    def rsa_private_key
      @rsa_private_key ||= OpenSSL::PKey::RSA.new(normalized_private_key)
    rescue OpenSSL::PKey::RSAError => e
      raise ConfigurationError, "GitHub App private key is invalid: #{e.message}"
    end

    def normalized_private_key
      private_key.to_s.gsub('\n', "\n")
    end
  end
end
