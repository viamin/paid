# frozen_string_literal: true

module Knowledge
  module Embeddings
    class ProxyGenerator
      attr_reader :project, :model, :dimensions

      def initialize(project:, provider_configs: nil, knowledge_run: nil, containerize: false,
        model: nil, dimensions: nil)
        @project = project
        @provider_configs = Array(provider_configs || Knowledge::RunnerConfiguration.for_embedding_candidate_runners(project: project))
        @knowledge_run = knowledge_run
        @containerize = containerize
        @model = (model.presence || resolve_user_setting_model).to_s
        @dimensions = dimensions || resolve_user_setting_dimensions
        @attempted_providers = existing_attempted_providers
        @failed = false
        @successful = false
        @last_error = nil
      end

      def call(texts:)
        return [] if texts.empty?
        raise EmbeddingError, "No embedding provider configured for project #{project.id}" if provider_configs.empty?

        last_error = nil

        provider_configs.each do |config|
          record_attempt!(config.runner)

          results = if use_container?
            container_runner.generate(texts: texts, provider: config.runner, model: model, dimensions: dimensions)
          else
            Generate.call(
              texts: texts,
              model: model,
              dimensions: dimensions,
              base_url: proxy_embeddings_url,
              headers: proxy_headers(config.runner)
            )
          end

          mark_success!(config.runner)
          return results
        rescue Knowledge::EmbeddingRunner::Error, EmbeddingError => e
          last_error = e
          mark_attempt_error!(config.runner, e)
          Rails.logger.warn(
            message: "knowledge.embeddings.provider_failed",
            project_id: project.id,
            knowledge_run_id: knowledge_run.id,
            provider: config.runner,
            error_class: e.class.name,
            error: e.message
          )
        end

        @failed = true
        @last_error = last_error
        raise EmbeddingError,
          "Embedding generation failed for providers #{attempted_providers.join(', ')}: #{last_error&.message}"
      end

      def close
        @container_runner&.cleanup!
        finalize_knowledge_run!
      end

      private

      attr_reader :attempted_providers

      attr_reader :provider_configs

      def use_container?
        @containerize && Knowledge::EmbeddingRunner.available?
      end

      def container_runner
        @container_runner ||= Knowledge::EmbeddingRunner.new(project: project, knowledge_run: knowledge_run)
      end

      def proxy_headers(provider)
        {
          "Authorization" => "Bearer paid-knowledge-run:#{knowledge_run.id}:#{knowledge_run.ensure_proxy_token!}",
          "X-Paid-Knowledge-Provider" => provider
        }
      end

      def proxy_embeddings_url
        "#{proxy_base_url}/api/proxy/openai/v1"
      end

      # Resolves the user-configurable embedding model from the project's
      # owner settings, falling back to the bundled default so unsaved
      # settings (or projects with no owner) still produce a usable value.
      def resolve_user_setting_model
        settings = user_settings
        return Generate::DEFAULT_MODEL unless settings

        resolved = settings.kb_embedding_model
        resolved.to_s.presence || Generate::DEFAULT_MODEL
      end

      # Resolves the user-configurable embedding dimensions, falling back
      # to the bundled default. Reading through the model's effective
      # accessor (rather than the raw column) keeps blank-string rows from
      # the legacy schema from blowing up the Qdrant index.
      def resolve_user_setting_dimensions
        settings = user_settings
        return Generate::DEFAULT_DIMENSIONS unless settings

        resolved = settings.kb_embedding_dimensions
        resolved.is_a?(Integer) && resolved.positive? ? resolved : Generate::DEFAULT_DIMENSIONS
      end

      def user_settings
        owner = project&.effective_owner
        return nil unless owner

        owner.settings
      rescue ActiveRecord::RecordNotFound
        nil
      end

      def proxy_base_url
        ENV["PAID_PROXY_URL"].presence ||
          Rails.application.config.x.proxy_url.presence ||
          "http://web:#{Rails.application.config.x.paid_proxy_port}"
      end

      def record_attempt!(provider)
        return if attempted_providers.include?(provider)

        attempted_providers << provider
        # Keep the local cache as plain provider names for retry/error reporting
        # while KnowledgeRun persists the full attempt hash with timestamps.
        knowledge_run.record_provider_attempt(provider)
      end

      def mark_success!(provider)
        @successful = true
        knowledge_run.mark_provider_attempt_outcome(provider: provider, outcome: "success")
        return if knowledge_run.final_provider == provider

        knowledge_run.update!(final_provider: provider)
      end

      def mark_attempt_error!(provider, error)
        knowledge_run.mark_provider_attempt_outcome(
          provider: provider,
          outcome: "provider_error",
          error_class: error.class.name,
          error_message: error.message
        )
      end

      def knowledge_run
        @knowledge_run ||= KnowledgeRun.create!(
          project: project,
          operation_type: "embedding",
          status: "running",
          max_tokens: embedding_max_tokens
        )
      end

      def embedding_max_tokens
        project.project_level_max_tokens_per_run || AgentRun::DEFAULT_MAX_TOKENS_PER_RUN
      end

      def finalize_knowledge_run!
        return unless @knowledge_run&.persisted?
        return unless @knowledge_run.active?

        if @failed
          @knowledge_run.fail!(
            reason: "all_providers_exhausted",
            error_class: @last_error&.class&.name,
            error_message: @last_error&.message
          )
        elsif @successful
          @knowledge_run.complete!
        else
          @knowledge_run.fail!(reason: "all_providers_exhausted")
        end
      rescue ActiveRecord::RecordInvalid => e
        Rails.logger.warn(
          message: "knowledge.embeddings.knowledge_run_finalize_failed",
          knowledge_run_id: @knowledge_run.id,
          error: e.message
        )
      end

      def existing_attempted_providers
        return [] unless @knowledge_run

        Array(@knowledge_run.provider_attempts).filter_map do |attempt|
          attempt.is_a?(Hash) ? attempt["provider"].presence : attempt.presence
        end
      end
    end
  end
end
