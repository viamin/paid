# frozen_string_literal: true

require "json"
require "open3"
require "time"
require "timeout"

module Runners
  class AuthHealth
    EXPIRING_SOON_THRESHOLD = 24.hours
    CLI_TIMEOUT_SECONDS = 5
    SUPPORTED_RUNNER_KEYS = %w[claude].freeze

    Result = Struct.new(
      :runner,
      :runner_key,
      :owner_name,
      :owner_email,
      :valid,
      :expires_at,
      :source,
      :error,
      keyword_init: true
    ) do
      def invalid?
        !valid
      end

      def expiring_soon?
        valid && expires_at.present? && expires_at <= Time.current + AuthHealth::EXPIRING_SOON_THRESHOLD
      end

      def status_label
        return "Invalid" if invalid?
        return "Expiring Soon" if expiring_soon?

        "Healthy"
      end

      def source_label
        source.to_s.humanize
      end
    end

    def self.call(...)
      new(...).call
    end

    def initialize(account:, host_forwarded_status_by_runner_key: nil)
      @account = account
      @host_forwarded_status_by_runner_key = host_forwarded_status_by_runner_key
    end

    def call
      supported_subscription_runners.map do |runner|
        build_result(runner)
      end
    end

    private

    attr_reader :account

    def supported_subscription_runners
      @supported_subscription_runners ||= Runner
        .joins(:user)
        .kept_only
        .where(users: { account_id: account.id }, auth_type: "subscription", runner_key: SUPPORTED_RUNNER_KEYS)
        .includes(:user)
        .ordered
    end

    def build_result(runner)
      status =
        if (credential = managed_credential_for(runner.runner_key))
          managed_token_status(credential)
        else
          cached_host_forwarded_status(runner.runner_key)
        end

      Result.new(
        runner: runner.display_name,
        runner_key: runner.runner_key,
        owner_name: runner.user.name.presence || runner.user.email,
        owner_email: runner.user.email,
        valid: status.fetch(:valid),
        expires_at: status[:expires_at],
        source: status.fetch(:source),
        error: status[:error]
      )
    end

    def managed_credential_for(runner_key)
      managed_credentials_by_runner_key[runner_key.to_s]
    end

    def managed_credentials_by_runner_key
      @managed_credentials_by_runner_key ||= supported_subscription_runners
        .map(&:runner_key)
        .uniq
        .index_with do |runner_key|
          latest_managed_credential_for(runner_key)
        end
    end

    def latest_managed_credential_for(runner_key)
      return if account.blank? || runner_key.blank?

      account.integration_credentials
        .for_category(:llm_provider)
        .for_service(runner_key)
        .order(created_at: :desc, id: :desc)
        .first
    end

    def managed_token_status(credential)
      error =
        if credential.revoked?
          "Managed token revoked"
        elsif credential.expired?
          "Managed token expired"
        end

      {
        valid: credential.active?,
        expires_at: credential.expires_at,
        source: :managed_token,
        error: error
      }
    end

    def cached_host_forwarded_status(runner_key)
      host_forwarded_status_by_runner_key[runner_key.to_s] ||= host_forwarded_status(runner_key)
    end

    def host_forwarded_status_by_runner_key
      @host_forwarded_status_by_runner_key ||= {}
    end

    def host_forwarded_status(runner_key)
      case runner_key.to_s
      when "claude"
        cli_claude_status || fallback_claude_status
      else
        {
          valid: false,
          expires_at: nil,
          source: :host_forwarded,
          error: "Auth health check not implemented for #{runner_key}"
        }
      end
    end

    def cli_claude_status
      stdout, stderr, status = Timeout.timeout(CLI_TIMEOUT_SECONDS) do
        Open3.capture3({}, "claude", "auth", "status", "--json")
      end
      payload = parse_json(stdout)
      return nil unless payload

      error = auth_error_message(payload)
      error ||= cli_error_message(payload, stderr: stderr, stdout: stdout) unless status.success?
      valid = status.success? && error.blank?

      {
        valid: valid,
        expires_at: extract_expires_at(payload),
        source: :host_forwarded,
        error: error
      }
    rescue Errno::ENOENT
      nil
    rescue Timeout::Error
      missing_host_forwarded_status("Claude auth status check timed out")
    rescue SystemCallError => e
      missing_host_forwarded_status("Claude auth status check failed: #{e.message}")
    end

    def fallback_claude_status
      credentials = read_claude_credentials
      oauth = credentials&.dig("claudeAiOauth")
      return missing_host_forwarded_status("No credentials found") unless credentials
      return missing_host_forwarded_status("No Claude OAuth credentials found") unless oauth.is_a?(Hash)

      expires_at = parse_expiry(oauth["expiresAt"] || oauth["expires_at"])
      return missing_host_forwarded_status("Missing Claude OAuth expiry") unless expires_at

      {
        valid: expires_at > Time.current,
        expires_at: expires_at,
        source: :host_forwarded,
        error: expires_at > Time.current ? nil : "Session expired"
      }
    rescue IOError, JSON::ParserError => e
      missing_host_forwarded_status(e.message)
    end

    def missing_host_forwarded_status(error)
      {
        valid: false,
        expires_at: nil,
        source: :host_forwarded,
        error: error
      }
    end

    def cli_error_message(payload, stderr:, stdout:)
      return stderr.presence || stdout.presence || "Claude authentication is unavailable" unless payload.is_a?(Hash)

      auth_error_message(payload) || stderr.presence || stdout.presence || "Claude authentication is unavailable"
    end

    def auth_error_message(payload)
      [
        payload["error"],
        payload["message"],
        payload.dig("auth", "error")
      ].find(&:present?)
    end

    def extract_expires_at(payload)
      parse_expiry(
        payload["expiresAt"] ||
          payload["expires_at"] ||
          payload.dig("claudeAiOauth", "expiresAt") ||
          payload.dig("claudeAiOauth", "expires_at") ||
          payload.dig("auth", "expiresAt") ||
          payload.dig("auth", "expires_at")
      )
    end

    def parse_json(raw)
      return nil if raw.blank?

      JSON.parse(raw)
    rescue JSON::ParserError
      nil
    end

    def read_claude_credentials
      path = claude_credentials_path
      return nil unless File.exist?(path)

      JSON.parse(File.read(path))
    rescue Errno::ENOENT
      nil
    rescue Errno::EACCES => e
      raise IOError, "Permission denied when reading Claude credentials at #{path}: #{e.message}"
    rescue JSON::ParserError => e
      raise JSON::ParserError, "Invalid JSON in Claude credentials at #{path}: #{e.message}"
    end

    def claude_credentials_path
      config_dir = ENV["CLAUDE_CONFIG_DIR"].presence || File.expand_path("~/.claude")
      File.join(config_dir, ".credentials.json")
    end

    def parse_expiry(value)
      return nil if value.blank?

      case value
      when Time
        value
      when Integer, Float
        Time.at(value)
      when String
        Time.parse(value)
      end
    rescue ArgumentError
      nil
    end
  end
end
