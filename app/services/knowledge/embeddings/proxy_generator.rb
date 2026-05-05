# frozen_string_literal: true

module Knowledge
  module Embeddings
    class ProxyGenerator
      attr_reader :project, :model, :dimensions

      def initialize(project:, provider_configs: nil, knowledge_run: nil, containerize: false)
        @project = project
        @provider_configs = Array(provider_configs || Knowledge::ProviderConfiguration.for_embedding_candidate_providers(project: project))
        @knowledge_run = knowledge_run
        @containerize = containerize
        @model = Generate::MODEL
        @dimensions = Generate::DIMENSIONS
        @attempted_providers = []
        @failed = false
        @successful = false
      end

      def call(texts:)
        return [] if texts.empty?
        raise EmbeddingError, "No embedding provider configured for project #{project.id}" if provider_configs.empty?

        last_error = nil

        provider_configs.each do |config|
          record_attempt!(config.provider)

          results = if use_container?
            container_runner.generate(texts: texts, provider: config.provider, model: model, dimensions: dimensions)
          else
            Generate.call(texts: texts, base_url: proxy_embeddings_url, headers: proxy_headers(config.provider))
          end

          mark_success!(config.provider)
          return results
        rescue Knowledge::EmbeddingRunner::Error, EmbeddingError => e
          last_error = e
          Rails.logger.warn(
            message: "knowledge.embeddings.provider_failed",
            project_id: project.id,
            knowledge_run_id: knowledge_run.id,
            provider: config.provider,
            error_class: e.class.name,
            error: e.message
          )
        end

        @failed = true
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

      def proxy_base_url
        ENV["PAID_PROXY_URL"].presence ||
          "http://web:#{Rails.application.config.x.paid_proxy_port}"
      end

      def record_attempt!(provider)
        return if attempted_providers.include?(provider)

        attempted_providers << provider
        knowledge_run.update!(provider_attempts: attempted_providers)
      end

      def mark_success!(provider)
        @successful = true
        return if knowledge_run.final_provider == provider

        knowledge_run.update!(final_provider: provider)
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

        @knowledge_run.update!(status: final_status)
      rescue ActiveRecord::RecordInvalid => e
        Rails.logger.warn(
          message: "knowledge.embeddings.knowledge_run_finalize_failed",
          knowledge_run_id: @knowledge_run.id,
          error: e.message
        )
      end

      def final_status
        return "failed" if @failed
        return "completed" if @successful

        "failed"
      end
    end
  end
end
