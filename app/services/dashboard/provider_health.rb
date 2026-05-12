# frozen_string_literal: true

module Dashboard
  class ProviderHealth
    CACHE_TTL = 20.seconds

    ProviderStatus = Struct.new(
      :provider,
      :owner_name,
      :owner_email,
      :auth_type,
      :status,
      :status_label,
      :available,
      :failure_count,
      :rate_limited_until,
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
      providers = provider_rows

      {
        providers: providers,
        total: providers.size,
        available: providers.count(&:available),
        rate_limited: providers.count { |provider| provider.status == :rate_limited },
        circuit_open: providers.count { |provider| provider.status == :circuit_open },
        recovering: providers.count { |provider| provider.status == :recovering },
        healthy: providers.any? && providers.all?(&:available)
      }
    end

    def provider_rows
      state_by_provider = provider_states.index_by(&:provider_name)

      configured_providers.map do |provider|
        build_provider_status(provider, state_by_provider[provider.state_key])
      end.sort_by { |provider| [ status_priority(provider.status), provider.provider.downcase, provider.owner_email.downcase ] }
    end

    def configured_providers
      @configured_providers ||= Provider
        .joins(:user)
        .where(users: { account_id: account.id })
        .for_agent_runs
        .includes(user: :user_setting)
        .ordered
    end

    def provider_states
      @provider_states ||= ProviderState
        .joins(:user)
        .where(users: { account_id: account.id }, provider_name: configured_providers.map(&:state_key))
        .includes(:user)
    end

    def build_provider_status(provider, state)
      state&.check_circuit_recovery!(timeout: circuit_breaker_timeout_for(provider))

      status =
        if state&.rate_limited?
          :rate_limited
        elsif state&.circuit_open?
          :circuit_open
        elsif state&.circuit_half_open?
          :recovering
        else
          :available
        end

      ProviderStatus.new(
        provider: provider.display_name,
        owner_name: provider.user.name.presence || provider.user.email,
        owner_email: provider.user.email,
        auth_type: provider.api_key? ? "API Key" : "Subscription",
        status: status,
        status_label: status.to_s.humanize,
        available: status == :available,
        failure_count: state&.failure_count || 0,
        rate_limited_until: state&.rate_limited_until
      )
    end

    def circuit_breaker_timeout_for(provider)
      provider.user.user_setting&.circuit_breaker_timeout_seconds || self.class.default_circuit_breaker_timeout
    end

    def status_priority(status)
      case status
      when :rate_limited then 0
      when :circuit_open then 1
      when :recovering then 2
      else 3
      end
    end

    def cache_key
      "dashboard/provider_health/#{account.id}"
    end

    def self.default_circuit_breaker_timeout
      UserSetting.column_defaults["circuit_breaker_timeout_seconds"]
    end
  end
end
