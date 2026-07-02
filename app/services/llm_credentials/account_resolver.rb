# frozen_string_literal: true

module LlmCredentials
  class AccountResolver
    Result = Data.define(:provider_api_key, :integration_credential) do
      def present?
        provider_api_key.present? || integration_credential.present?
      end

      def provider_api_key?
        provider_api_key.present?
      end

      def integration_credential?
        integration_credential.present?
      end

      def api_secret
        provider_api_key&.api_key.to_s.presence || integration_credential&.api_secret
      end
    end

    def self.call(...)
      new(...).call
    end

    def initialize(account:, runner_key:, api_service_type: nil, tenant_setting: nil)
      @account = account
      @runner_key = runner_key
      @api_service_type = api_service_type
      @tenant_setting = tenant_setting
    end

    def call
      provider_api_key = resolve_provider_api_key
      return Result.new(provider_api_key:, integration_credential: nil) if provider_api_key.present?

      Result.new(provider_api_key: nil, integration_credential: resolve_integration_credential)
    end

    private

    attr_reader :account, :runner_key, :api_service_type, :tenant_setting

    def resolve_provider_api_key
      return if api_service_type.blank?

      tenant_setting&.provider_api_key_for(api_service_type)
    end

    def resolve_integration_credential
      return if account.blank? || runner_key.blank?

      account.integration_credentials.active
        .for_category(:llm_provider)
        .for_service(runner_key)
        .order(created_at: :desc, id: :desc)
        .first
    end
  end
end
