# frozen_string_literal: true

module Knowledge
  class ProviderConfiguration
    Result = Struct.new(:provider, :provider_label, :api_key, :api_base_url, :api_key_record, :source, keyword_init: true)

    def self.for_embedding(project:)
      new(project:).for_embedding
    end

    def self.for_embedding_candidates(project:)
      new(project:).for_embedding_candidates
    end

    def initialize(project:)
      @project = project
    end

    def for_embedding
      for_embedding_candidates.first
    end

    def for_embedding_candidates
      configured_embedding_providers.filter_map do |provider|
        build_embedding_config(provider)
      end
    end

    private

    attr_reader :project

    def owner
      @owner ||= project&.effective_owner
    end

    def user_setting
      @user_setting ||= owner&.settings
    end

    def configured_embedding_providers
      return [ UserSetting::KB_EMBEDDING_PROVIDER_DEFAULT ] unless user_setting

      Knowledge::ProviderSelector.for_embedding(user_setting: user_setting)
    end

    def build_embedding_config(provider)
      return log_unsupported_provider(provider) unless UserSetting::KB_EMBEDDING_PROVIDERS.include?(provider)

      config = Provider::DIRECT_OUTBOUND_API_PROVIDERS[provider]
      return log_unsupported_provider(provider) unless config

      api_key_record = provider_api_key_record(config.fetch(:service_type))

      if api_key_record
        Result.new(
          provider: provider,
          provider_label: config.fetch(:label, provider.to_s.titleize),
          api_key: api_key_record.api_key,
          api_base_url: api_base_url_for(provider, config),
          api_key_record: api_key_record,
          source: :user_key
        )
      elsif provider == "openai" && ENV["OPENAI_API_KEY"].present?
        Result.new(
          provider: provider,
          provider_label: config.fetch(:label, provider.to_s.titleize),
          api_key: ENV["OPENAI_API_KEY"],
          api_base_url: api_base_url_for(provider, config),
          api_key_record: nil,
          source: :platform_env
        )
      end
    end

    def api_base_url_for(provider, config)
      return ENV.fetch("OPENAI_API_BASE_URL", "https://api.openai.com") if provider == "openai"

      config.fetch(:base_url)
    end

    def provider_api_key_record(service_type)
      owner
        &.provider_api_keys
        &.for_api_service_type(service_type)
        &.order(created_at: :desc, id: :desc)
        &.first
    end

    def log_unsupported_provider(provider)
      Rails.logger.warn(
        message: "knowledge.provider_configuration.unsupported_embedding_provider",
        project_id: project&.id,
        provider: provider
      )
      nil
    end
  end
end
