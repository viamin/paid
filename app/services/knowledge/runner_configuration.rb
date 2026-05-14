# frozen_string_literal: true

module Knowledge
  class RunnerConfiguration
    Result = Struct.new(:runner, :runner_label, :api_key, :api_base_url, :api_key_record, :source, keyword_init: true)

    def self.for_embedding(project:)
      new(project:).for_embedding
    end

    def self.for_embedding_candidates(project:)
      new(project:).for_embedding_candidates
    end

    def self.for_embedding_candidate_runners(project:)
      new(project:).for_embedding_candidate_runners
    end

    def initialize(project:)
      @project = project
    end

    def for_embedding
      for_embedding_candidates.first
    end

    def for_embedding_candidates
      configured_embedding_runners.filter_map do |runner|
        build_embedding_config(runner)
      end
    end

    def for_embedding_candidate_runners
      configured_embedding_runners.filter_map do |runner|
        next log_unsupported_runner(runner) unless UserSetting::KB_EMBEDDING_RUNNERS.include?(runner)
        config = Runner::DIRECT_OUTBOUND_API_PROVIDERS[runner]
        next log_unsupported_runner(runner) unless config
        next unless embedding_credentials_available?(runner, config)

        Result.new(runner: runner)
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

    def configured_embedding_runners
      return [ UserSetting::KB_EMBEDDING_RUNNER_DEFAULT ] unless user_setting

      Knowledge::RunnerSelector.for_embedding(user_setting: user_setting)
    end

    def build_embedding_config(runner)
      return log_unsupported_runner(runner) unless UserSetting::KB_EMBEDDING_RUNNERS.include?(runner)

      config = Runner::DIRECT_OUTBOUND_API_PROVIDERS[runner]
      return log_unsupported_runner(runner) unless config

      api_key_record = provider_api_key_record(config.fetch(:service_type))

      if api_key_record
        Result.new(
          runner: runner,
          runner_label: config.fetch(:label, runner.to_s.titleize),
          api_key: api_key_record.api_key,
          api_base_url: api_base_url_for(runner, config),
          api_key_record: api_key_record,
          source: :user_key
        )
      elsif runner == "openai" && platform_openai_api_key.present?
        Result.new(
          runner: runner,
          runner_label: config.fetch(:label, runner.to_s.titleize),
          api_key: platform_openai_api_key,
          api_base_url: api_base_url_for(runner, config),
          api_key_record: nil,
          source: :platform_env
        )
      end
    end

    def api_base_url_for(runner, config)
      return ENV.fetch("OPENAI_API_BASE_URL", "https://api.openai.com") if runner == "openai"

      config.fetch(:base_url)
    end

    def provider_api_key_record(service_type)
      owner
        &.provider_api_keys
        &.for_api_service_type(service_type)
        &.order(created_at: :desc, id: :desc)
        &.first
    end

    def embedding_credentials_available?(runner, config)
      return true if runner == "openai" && platform_openai_api_key_available?

      owner
        &.provider_api_keys
        &.for_api_service_type(config.fetch(:service_type))
        &.exists? || false
    end

    def platform_openai_api_key_available?
      platform_openai_api_key.present?
    end

    def platform_openai_api_key
      Rails.application.credentials.dig(:llm, :openai_api_key).presence || ENV["OPENAI_API_KEY"].presence
    end

    def log_unsupported_runner(runner)
      Rails.logger.warn(
        message: "knowledge.runner_configuration.unsupported_embedding_runner",
        project_id: project&.id,
        runner: runner
      )
      nil
    end
  end
end
