# frozen_string_literal: true

module Capacity
  module InfrastructureLimits
    REQUIRED_PRODUCTION_KEYS = %w[
      MAX_GLOBAL_REQUESTED_CPU_QUOTA
      MAX_BACKEND_REQUESTED_CPU_QUOTA
      MAX_GLOBAL_REQUESTED_MEMORY_BYTES
      MAX_BACKEND_REQUESTED_MEMORY_BYTES
      MAX_GLOBAL_REQUESTED_DISK_BYTES
      MAX_BACKEND_REQUESTED_DISK_BYTES
      MAX_EXECUTION_CPU_QUOTA
      MAX_EXECUTION_MEMORY_BYTES
      MAX_EXECUTION_DISK_BYTES
      PROVISIONING_RATE_WINDOW_SECONDS
      MAX_GLOBAL_PROVISIONINGS_PER_WINDOW
      MAX_ACCOUNT_PROVISIONINGS_PER_WINDOW
      MAX_PROJECT_PROVISIONINGS_PER_WINDOW
    ].freeze

    DEVELOPMENT_DEFAULTS = {
      "MAX_GLOBAL_REQUESTED_CPU_QUOTA" => 8_000_000,
      "MAX_BACKEND_REQUESTED_CPU_QUOTA" => 2_000_000,
      "MAX_GLOBAL_REQUESTED_MEMORY_BYTES" => 128.gigabytes,
      "MAX_BACKEND_REQUESTED_MEMORY_BYTES" => 32.gigabytes,
      "MAX_GLOBAL_REQUESTED_DISK_BYTES" => 256.gigabytes,
      "MAX_BACKEND_REQUESTED_DISK_BYTES" => 64.gigabytes,
      "MAX_EXECUTION_CPU_QUOTA" => 400_000,
      "MAX_EXECUTION_MEMORY_BYTES" => 16.gigabytes,
      "MAX_EXECUTION_DISK_BYTES" => 4.gigabytes,
      "PROVISIONING_RATE_WINDOW_SECONDS" => 600,
      "MAX_GLOBAL_PROVISIONINGS_PER_WINDOW" => 25,
      "MAX_ACCOUNT_PROVISIONINGS_PER_WINDOW" => 10,
      "MAX_PROJECT_PROVISIONINGS_PER_WINDOW" => 5,
      "INFRA_SPEND_RATE_CENTS_PER_HOUR" => 0,
      "INFRA_SPEND_PROJECTION_SECONDS" => 3600,
      "MAX_GLOBAL_INFRA_SPEND_HOURLY_CENTS" => 0,
      "MAX_GLOBAL_INFRA_SPEND_DAILY_CENTS" => 0,
      "MAX_ACCOUNT_INFRA_SPEND_HOURLY_CENTS" => 0,
      "MAX_ACCOUNT_INFRA_SPEND_DAILY_CENTS" => 0,
      "MAX_PROJECT_INFRA_SPEND_HOURLY_CENTS" => 0,
      "MAX_PROJECT_INFRA_SPEND_DAILY_CENTS" => 0,
      "MAX_RUNNER_INFRA_SPEND_HOURLY_CENTS" => 0,
      "MAX_RUNNER_INFRA_SPEND_DAILY_CENTS" => 0
    }.freeze

    class << self
      def current(host: nil, env: ENV)
        {
          global_requested_cpu_quota_limit: integer_env(env, "MAX_GLOBAL_REQUESTED_CPU_QUOTA"),
          host_requested_cpu_quota_limit: integer_env(env, host_key("MAX_BACKEND_REQUESTED_CPU_QUOTA", host), fallback_key: "MAX_BACKEND_REQUESTED_CPU_QUOTA"),
          global_requested_memory_bytes_limit: integer_env(env, "MAX_GLOBAL_REQUESTED_MEMORY_BYTES"),
          host_requested_memory_bytes_limit: integer_env(env, host_key("MAX_BACKEND_REQUESTED_MEMORY_BYTES", host), fallback_key: "MAX_BACKEND_REQUESTED_MEMORY_BYTES"),
          global_requested_disk_bytes_limit: integer_env(env, "MAX_GLOBAL_REQUESTED_DISK_BYTES"),
          host_requested_disk_bytes_limit: integer_env(env, host_key("MAX_BACKEND_REQUESTED_DISK_BYTES", host), fallback_key: "MAX_BACKEND_REQUESTED_DISK_BYTES"),
          max_execution_cpu_quota_limit: integer_env(env, "MAX_EXECUTION_CPU_QUOTA"),
          max_execution_memory_bytes_limit: integer_env(env, "MAX_EXECUTION_MEMORY_BYTES"),
          max_execution_disk_bytes_limit: integer_env(env, "MAX_EXECUTION_DISK_BYTES"),
          provisioning_rate_window_seconds: integer_env(env, "PROVISIONING_RATE_WINDOW_SECONDS"),
          global_provisionings_per_window_limit: integer_env(env, "MAX_GLOBAL_PROVISIONINGS_PER_WINDOW"),
          account_provisionings_per_window_limit: integer_env(env, "MAX_ACCOUNT_PROVISIONINGS_PER_WINDOW"),
          project_provisionings_per_window_limit: integer_env(env, "MAX_PROJECT_PROVISIONINGS_PER_WINDOW"),
          infra_spend_rate_cents_per_hour: rate_cents_per_hour(host: host, env: env),
          infra_spend_projection_seconds: integer_env(env, "INFRA_SPEND_PROJECTION_SECONDS"),
          global_infra_spend_hourly_limit_cents: integer_env(env, "MAX_GLOBAL_INFRA_SPEND_HOURLY_CENTS"),
          global_infra_spend_daily_limit_cents: integer_env(env, "MAX_GLOBAL_INFRA_SPEND_DAILY_CENTS"),
          account_infra_spend_hourly_limit_cents: integer_env(env, "MAX_ACCOUNT_INFRA_SPEND_HOURLY_CENTS"),
          account_infra_spend_daily_limit_cents: integer_env(env, "MAX_ACCOUNT_INFRA_SPEND_DAILY_CENTS"),
          project_infra_spend_hourly_limit_cents: integer_env(env, "MAX_PROJECT_INFRA_SPEND_HOURLY_CENTS"),
          project_infra_spend_daily_limit_cents: integer_env(env, "MAX_PROJECT_INFRA_SPEND_DAILY_CENTS"),
          runner_infra_spend_hourly_limit_cents: integer_env(env, "MAX_RUNNER_INFRA_SPEND_HOURLY_CENTS"),
          runner_infra_spend_daily_limit_cents: integer_env(env, "MAX_RUNNER_INFRA_SPEND_DAILY_CENTS")
        }
      end

      def rate_cents_per_hour(host: nil, env: ENV)
        integer_env(
          env,
          host_key("INFRA_SPEND_RATE_CENTS_PER_HOUR", host),
          fallback_key: "INFRA_SPEND_RATE_CENTS_PER_HOUR"
        )
      end

      def max_rate_cents_per_hour(env: ENV)
        configured_rates = env.filter_map do |key, value|
          next unless key.match?(/\AINFRA_SPEND_RATE_CENTS_PER_HOUR(?:__.+)?\z/)

          Integer(value, exception: false)
        end

        (configured_rates << integer_env(env, "INFRA_SPEND_RATE_CENTS_PER_HOUR")).compact.max.to_i
      end

      def production_errors(env: ENV)
        REQUIRED_PRODUCTION_KEYS.filter_map do |key|
          value = Integer(env[key], exception: false)
          next if value.present? && value.positive?

          "#{key} must be set to a positive integer"
        end
      end

      private

      def integer_env(env, key, fallback_key: nil)
        raw = env[key].presence || (fallback_key && env[fallback_key].presence)
        raw = DEVELOPMENT_DEFAULTS.fetch(fallback_key || key).to_s if raw.blank?
        Integer(raw, exception: false)
      end

      def host_key(base, host)
        return base if host.blank?

        "#{base}__#{host.to_s.upcase.gsub(/[^A-Z0-9]+/, "_")}"
      end
    end
  end
end
