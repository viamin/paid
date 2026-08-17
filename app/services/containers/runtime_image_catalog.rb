# frozen_string_literal: true

require "json"

module Containers
  class RuntimeImageCatalog
    class Error < StandardError; end
    class UnknownProfileError < Error; end
    class UnknownReferenceError < Error; end
    class InactiveImageError < Error; end

    Identity = Data.define(
      :requested_image,
      :reference,
      :digest,
      :architecture,
      :registry,
      :repository,
      :status
    ) do
      def image
        "#{registry}/#{repository}@#{digest}"
      end
    end

    ENV_DIGESTS_KEY = "PAID_AGENT_RUNTIME_DIGESTS"

    def self.default
      @default ||= new(Rails.application.config_for(:agent_runtime_images))
    end

    def initialize(config)
      @config = stringify_keys(config)
    end

    def identity_for(requested_image:, provenance_reference: nil)
      # @spec IMMUTABLE-IMAGE-001, IMMUTABLE-IMAGE-004, IMMUTABLE-IMAGE-005
      profile = profile_for(requested_image.to_s)
      reference = provenance_reference.presence || profile.fetch("default_reference")
      identity = profile.fetch("identities", {}).fetch(reference) do
        raise UnknownReferenceError, "Unknown runtime image reference #{reference.inspect} for #{requested_image.inspect}"
      end
      status = identity.fetch("status", "active")
      raise InactiveImageError, "Runtime image reference #{reference.inspect} is #{status}" unless status == "active"

      Identity.new(
        requested_image: requested_image.to_s,
        reference: reference,
        digest: identity.fetch("digest"),
        architecture: identity.fetch("architecture"),
        registry: identity["registry"].presence || profile["registry"].presence || @config.fetch("registry"),
        repository: identity["repository"].presence || profile["repository"].presence || @config.fetch("repository"),
        status: status
      )
    end

    private

    def profile_for(requested_image)
      config_profiles.fetch(requested_image) do
        env_profiles.fetch(requested_image) do
          raise UnknownProfileError, "No immutable runtime image configured for #{requested_image.inspect}"
        end
      end
    end

    def config_profiles
      @config.fetch("profiles", {})
    end

    def env_profiles
      @env_profiles ||= stringify_keys(parsed_env_profiles).transform_values do |profile|
        normalize_env_profile(profile)
      end
    end

    def parsed_env_profiles
      raw = ENV.fetch(ENV_DIGESTS_KEY, "{}")
      JSON.parse(raw)
    rescue JSON::ParserError => e
      raise Error, "Invalid #{ENV_DIGESTS_KEY}: #{e.message}"
    end

    def normalize_env_profile(profile)
      profile = stringify_keys(profile)
      return profile if profile.key?("identities")

      reference = profile["provenance_reference"].presence || "env-configured"
      {
        "default_reference" => reference,
        "identities" => {
          reference => profile.merge("status" => "active")
        }
      }
    end

    def stringify_keys(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, nested), result|
          result[key.to_s] = stringify_keys(nested)
        end
      when Array
        value.map { |item| stringify_keys(item) }
      else
        value
      end
    end
  end
end
