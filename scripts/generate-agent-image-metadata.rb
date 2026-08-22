# frozen_string_literal: true

require "json"
require "time"

# Emits the CI metadata envelope for a smoke-tested paid-agent image.
#
# @spec IMMUTABLE-IMAGE-007
class AgentImageMetadataGenerator
  DIGEST_PATTERN = /\Asha256:[0-9a-f]{64}\z/
  ARCHITECTURE_ALIASES = {
    "x64" => "amd64",
    "x86_64" => "amd64",
    "amd64" => "amd64",
    "aarch64" => "arm64",
    "arm64" => "arm64"
  }.freeze

  def initialize(env = ENV)
    @env = env
  end

  def call
    output_path = fetch("OUTPUT_PATH")
    envelope = {
      "schema_version" => 1,
      "generated_at" => iso8601(fetch("BUILT_AT")),
      "registry_record" => registry_record,
      "activation" => activation,
      "runtime_catalog_patch" => runtime_catalog_patch
    }

    File.write(output_path, JSON.pretty_generate(envelope) + "\n")
  end

  private

  attr_reader :env

  def registry_record
    {
      "name" => fetch("PROFILE_NAME"),
      "tag" => fetch("IMAGE_TAG"),
      "registry" => fetch("REGISTRY"),
      "repository" => fetch("REPOSITORY"),
      "digest" => digest,
      "architecture" => architecture,
      "built_at" => iso8601(fetch("BUILT_AT")),
      "status" => "active",
      "provenance" => provenance,
      "metadata" => metadata
    }
  end

  def provenance
    {
      "source_commit" => fetch("GIT_SHA"),
      "build_timestamp" => iso8601(fetch("BUILT_AT")),
      "ci_provenance_url" => fetch("CI_PROVENANCE_URL"),
      "lockfile" => compact_hash(
        "bundler_version" => fetch("BUNDLER_VERSION"),
        "ruby_maat_version" => fetch("RUBY_MAAT_VERSION"),
        "agent_harness_version" => fetch("AGENT_HARNESS_VERSION"),
        "agent_harness_git_ref" => optional("AGENT_HARNESS_GIT_REF")
      ),
      "ci" => compact_hash(
        "provider" => "github_actions",
        "workflow" => optional("GITHUB_WORKFLOW"),
        "repository" => optional("GITHUB_REPOSITORY"),
        "run_id" => optional("GITHUB_RUN_ID"),
        "run_attempt" => optional("GITHUB_RUN_ATTEMPT")
      )
    }
  end

  def metadata
    {
      "requested_image" => fetch("REQUESTED_IMAGE"),
      "resolved_image" => resolved_image,
      "provenance_reference" => provenance_reference,
      "verification" => {
        "tested" => true,
        "checks" => verified_checks
      }
    }
  end

  def activation
    {
      "requested_image" => fetch("REQUESTED_IMAGE"),
      "default_reference" => provenance_reference,
      "candidate_reference" => provenance_reference,
      "status" => "active",
      "tested" => true,
      "rollback_strategy" => "select a prior active provenance_reference without moving the mutable tag"
    }
  end

  def runtime_catalog_patch
    {
      "profiles" => {
        fetch("REQUESTED_IMAGE") => {
          # Emit an additive patch so downstream activation can promote the new
          # default reference without overwriting the full identities map.
          "operations" => {
            "set_default_reference" => provenance_reference,
            "upsert_identities" => {
              provenance_reference => {
                "digest" => digest,
                "architecture" => architecture,
                "registry" => fetch("REGISTRY"),
                "repository" => fetch("REPOSITORY"),
                "status" => "active"
              }
            }
          }
        }
      }
    }
  end

  def resolved_image
    "#{fetch("REGISTRY")}/#{fetch("REPOSITORY")}@#{digest}"
  end

  def provenance_reference
    @provenance_reference ||= begin
      explicit = optional("PROVENANCE_REFERENCE")
      if explicit
        explicit
      else
        short_sha = fetch("GIT_SHA")[0, 12]
        date = Time.iso8601(fetch("BUILT_AT")).utc.strftime("%Y-%m-%d")
        "#{slug(fetch("PROFILE_NAME"))}-#{architecture}-#{date}-#{short_sha}"
      end
    end
  end

  def digest
    @digest ||= begin
      value = fetch("DIGEST").downcase
      raise ArgumentError, "DIGEST must be sha256:<64 hex>" unless value.match?(DIGEST_PATTERN)

      value
    end
  end

  def architecture
    @architecture ||= begin
      normalized = ARCHITECTURE_ALIASES.fetch(fetch("ARCHITECTURE").downcase) do
        raise ArgumentError, "unsupported ARCHITECTURE"
      end
      normalized
    end
  end

  def verified_checks
    checks = fetch("VERIFIED_CHECKS").split(",").map(&:strip).reject(&:empty?)
    raise ArgumentError, "VERIFIED_CHECKS must include at least one check" if checks.empty?

    checks
  end

  def fetch(key)
    value = env[key]
    raise ArgumentError, "#{key} is required" if value.nil? || value.strip.empty?

    value.strip
  end

  def optional(key)
    value = env[key]
    return nil if value.nil?

    stripped = value.strip
    stripped.empty? ? nil : stripped
  end

  def iso8601(value)
    Time.iso8601(value).utc.iso8601
  end

  def slug(value)
    value.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-+\z/, "")
  end

  def compact_hash(hash)
    hash.each_with_object({}) do |(key, value), result|
      result[key] = value unless value.nil?
    end
  end
end

AgentImageMetadataGenerator.new.call
