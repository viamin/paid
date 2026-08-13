# frozen_string_literal: true

module Dashboard
  # Summarizes GitHub credential health (App installations and PATs) for an
  # account so per-installation rate-limit usage is observable on the
  # dashboard. Each credential maps to a credential-scoped GithubHealthState
  # endpoint, so App installation quotas (15,000/hr per installation) never
  # collide with per-account PAT quotas (5,000/hr shared across projects).
  class GithubHealth
    CACHE_TTL = 20.seconds

    CredentialStatus = Struct.new(
      :label,
      :auth_source,
      :endpoint,
      :status,
      :status_label,
      :available,
      :inactive,
      :rate_limit_remaining,
      :rate_limit_limit,
      :rate_limit_usage_percent,
      :rate_limit_reset_at,
      :rate_limited_until,
      :failure_count,
      :last_observed_at,
      keyword_init: true
    )

    def self.call(...)
      new(...).call
    end

    def initialize(account:)
      @account = account
    end

    def call
      Rails.cache.fetch(cache_key, expires_in: CACHE_TTL) { build_payload }
    end

    private

    attr_reader :account

    def build_payload
      statuses = credential_statuses

      {
        credentials: statuses,
        total: statuses.size,
        app_count: statuses.count { |status| status.auth_source == "app" },
        pat_count: statuses.count { |status| status.auth_source == "pat" },
        rate_limited: statuses.count { |status| status.status == :rate_limited },
        circuit_open: statuses.count { |status| status.status == :circuit_open },
        inactive: statuses.count { |status| inactive_status?(status.status) },
        has_github_credentials: statuses.any?,
        healthy: statuses.any? && statuses.all?(&:available)
      }
    end

    def credential_statuses
      states = health_states_by_endpoint
      installation_statuses(states) + token_statuses(states)
    end

    def installation_statuses(states)
      account.github_installations.map do |installation|
        endpoint = GithubHealthState.endpoint_for_github_installation(installation.github_installation_id)
        build_status(
          label: installation_label(installation),
          auth_source: "app",
          endpoint: endpoint,
          state: states[endpoint],
          inactive_status: inactive_installation_status(installation)
        )
      end
    end

    def token_statuses(states)
      account.github_tokens.map do |token|
        endpoint = GithubHealthState.endpoint_for_github_token(token.id)
        build_status(
          label: token.name,
          auth_source: "pat",
          endpoint: endpoint,
          state: states[endpoint],
          inactive_status: inactive_token_status(token)
        )
      end
    end

    def build_status(label:, auth_source:, endpoint:, state:, inactive_status:)
      state&.check_circuit_recovery!

      status =
        if inactive_status
          inactive_status
        elsif state&.rate_limited?
          :rate_limited
        elsif state&.circuit_open?
          :circuit_open
        elsif state&.circuit_half_open?
          :recovering
        else
          :available
        end

      CredentialStatus.new(
        label: label,
        auth_source: auth_source,
        endpoint: endpoint,
        status: status,
        status_label: status.to_s.humanize,
        available: status == :available,
        inactive: inactive_status?(status),
        rate_limit_remaining: state&.rate_limit_remaining,
        rate_limit_limit: state&.rate_limit_limit,
        rate_limit_usage_percent: state&.rate_limit_usage_percent,
        rate_limit_reset_at: state&.rate_limit_reset_at,
        rate_limited_until: state&.rate_limited_until,
        failure_count: state&.failure_count || 0,
        last_observed_at: state&.rate_limit_observed_at
      )
    end

    def inactive_installation_status(installation)
      return :suspended if installation.suspended?
      return :revoked if installation.revoked?

      nil
    end

    def inactive_token_status(token)
      return :revoked if token.revoked?
      return :expired if token.expired?

      nil
    end

    def inactive_status?(status)
      %i[suspended revoked expired].include?(status)
    end

    def installation_label(installation)
      login = installation.account_login.presence || "installation"
      target = installation.target_type.presence || "GitHub App"
      "#{login} (#{target})"
    end

    def health_states_by_endpoint
      @health_states_by_endpoint ||= GithubHealthState.where(endpoint: credential_endpoints).index_by(&:endpoint)
    end

    def credential_endpoints
      installation_endpoints + token_endpoints
    end

    def installation_endpoints
      account.github_installations.map do |installation|
        GithubHealthState.endpoint_for_github_installation(installation.github_installation_id)
      end
    end

    def token_endpoints
      account.github_tokens.map { |token| GithubHealthState.endpoint_for_github_token(token.id) }
    end

    def cache_key
      "dashboard/github_health/#{account.id}"
    end
  end
end
