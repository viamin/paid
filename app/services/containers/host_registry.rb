# frozen_string_literal: true

require "yaml"

module Containers
  class HostRegistry
    FALLBACK_DISABLED = "disabled"
    FALLBACK_FIRST_HEALTHY = "first_healthy"
    FALLBACK_POLICIES = [ FALLBACK_DISABLED, FALLBACK_FIRST_HEALTHY ].freeze

    HostDefinition = Data.define(:identifier, :backend, :max_concurrent_runs, :fallback_enabled)

    class Registry
      attr_reader :default_host, :fallback_policy, :hosts

      def initialize(default_host:, fallback_policy:, hosts:)
        @default_host = default_host
        @fallback_policy = fallback_policy
        @hosts = hosts
      end

      def host(identifier)
        hosts.find { |entry| entry.identifier == identifier.to_s }
      end

      def host_limit_for(identifier)
        host(identifier)&.max_concurrent_runs
      end

      def fallback_candidates_for(identifier)
        hosts
          .select(&:fallback_enabled)
          .map(&:identifier)
          .reject { |candidate| candidate == identifier.to_s }
      end
    end

    class << self
      def load(...)
        new(...).load
      end
    end

    def initialize(env: ENV)
      @env = env
    end

    def load
      return single_backend_registry unless multi_backend_mode?

      parsed_config = config_payload
      host_entries = build_hosts(parsed_config.fetch("hosts", {}))
      default_host = parsed_config["default_host"].presence || host_entries.first&.identifier
      fallback_policy = normalize_fallback_policy(parsed_config["fallback"])

      Registry.new(
        default_host: default_host,
        fallback_policy: fallback_policy,
        hosts: host_entries
      )
    end

    private

    attr_reader :env

    def multi_backend_mode?
      env.fetch("CONTAINER_BACKEND", "local").to_s == "multi"
    end

    def single_backend_registry
      active_backend = Containers.backend

      Registry.new(
        default_host: active_backend.identifier,
        fallback_policy: FALLBACK_DISABLED,
        hosts: [
          HostDefinition.new(
            identifier: active_backend.identifier,
            backend: active_backend,
            max_concurrent_runs: nil,
            fallback_enabled: false
          )
        ]
      )
    end

    def config_payload
      raw = env["CONTAINER_BACKENDS_CONFIG"].to_s
      return {} if raw.blank?

      parsed = YAML.safe_load(raw, permitted_classes: [], aliases: false)
      return {} unless parsed.is_a?(Hash)

      parsed
    rescue Psych::SyntaxError => e
      raise ArgumentError, "Invalid CONTAINER_BACKENDS_CONFIG: #{e.message}"
    end

    def build_hosts(hosts_config)
      hosts_config.filter_map do |identifier, raw_config|
        next unless raw_config.is_a?(Hash)

        backend = build_backend(identifier, raw_config)
        max_concurrent_runs = raw_config.dig("concurrency", "max_concurrent_runs")

        HostDefinition.new(
          identifier: identifier.to_s,
          backend: backend,
          max_concurrent_runs: max_concurrent_runs.present? ? Integer(max_concurrent_runs) : nil,
          fallback_enabled: ActiveModel::Type::Boolean.new.cast(raw_config.fetch("fallback_enabled", true))
        )
      end
    end

    def build_backend(identifier, raw_config)
      case raw_config.fetch("type", nil).to_s
      when "local"
        Containers::Backends::LocalDocker.new(identifier: identifier.to_s)
      when "remote"
        Containers::Backends::RemoteDocker.new(
          host: raw_config.fetch("host"),
          identifier: identifier.to_s,
          tls_config: {
            client_cert: raw_config.dig("tls", "client_cert"),
            client_key: raw_config.dig("tls", "client_key"),
            ssl_ca_file: raw_config.dig("tls", "ca_file")
          }
        )
      else
        raise ArgumentError, "Unsupported Docker host type for #{identifier.inspect}"
      end
    end

    def normalize_fallback_policy(value)
      normalized = value.to_s.presence || FALLBACK_DISABLED
      return normalized if FALLBACK_POLICIES.include?(normalized)

      FALLBACK_DISABLED
    end
  end
end
