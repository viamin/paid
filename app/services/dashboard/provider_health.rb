# frozen_string_literal: true

module Dashboard
  class ProviderHealth < RunnerHealth
    ProviderStatus = Struct.new(
      :provider,
      :owner_name,
      :owner_email,
      :auth_type,
      :status,
      :status_label,
      :available,
      :failure_count,
      :attempt_count,
      :rate_limited_until,
      keyword_init: true
    )

    def call
      legacy_provider_payload(super)
    end

    private

    def legacy_provider_payload(payload)
      payload.merge(providers: Array(payload[:runners]).map { |runner_status| provider_status_for(runner_status) })
    end

    def provider_status_for(runner_status)
      ProviderStatus.new(
        provider: runner_status.runner,
        owner_name: runner_status.owner_name,
        owner_email: runner_status.owner_email,
        auth_type: runner_status.auth_type,
        status: runner_status.status,
        status_label: runner_status.status_label,
        available: runner_status.available,
        failure_count: runner_status.failure_count,
        attempt_count: runner_status.attempt_count,
        rate_limited_until: runner_status.rate_limited_until
      )
    end
  end
end
