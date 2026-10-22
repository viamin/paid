# frozen_string_literal: true

module Knowledge
  class RunnerConfiguration
    class Result
      attr_reader :runner, :runner_label, :api_key, :api_base_url, :api_key_record, :source

      def initialize(
        runner: nil,
        runner_label: nil,
        provider: nil,
        provider_label: nil,
        api_key: nil,
        api_base_url: nil,
        api_key_record: nil,
        source: nil
      )
        @runner = runner || provider
        @runner_label = runner_label || provider_label
        @api_key = api_key
        @api_base_url = api_base_url
        @api_key_record = api_key_record
        @source = source
      end

      alias_method :provider, :runner
      alias_method :provider_label, :runner_label
    end

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
        next log_unsupported_runner(runner) unless Runner::DIRECT_OUTBOUND_API_PROVIDERS[runner]
        next unless embedding_readiness_for(runner).status == "ready"

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

      credential = CredentialSelection.call(owner:, operation: :embedding, runner: runner)

      if credential.status == :ready
        Result.new(
          runner: runner,
          runner_label: config.fetch(:label, runner.to_s.titleize),
          api_key: credential.api_key,
          api_base_url: api_base_url_for(runner, config),
          api_key_record: credential.api_key_record,
          source: credential.source == :platform_fallback ? :platform_env : :user_key
        )
      end
    end

    def api_base_url_for(runner, config)
      return ENV.fetch("OPENAI_API_BASE_URL", "https://api.openai.com") if runner == "openai"

      config.fetch(:base_url)
    end

    # @spec KNOWLEDGE-DASHBOARD-001
    def embedding_readiness_for(runner)
      RunnerReadiness.call(owner:, operation: :embedding, runner:)
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
