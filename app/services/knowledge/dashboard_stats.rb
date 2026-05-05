# frozen_string_literal: true

module Knowledge
  class DashboardStats
    CACHE_TTL = 60.seconds
    PIPELINE_LOOKBACK = 30.days
    FINISHED_STATUSES_SQL = KnowledgeRun::FINISHED_STATUSES.map { |status| "'#{status}'" }.join(", ").freeze

    attr_reader :account

    def initialize(account:)
      @account = account
    end

    def self.call(...)
      new(...).call
    end

    def call
      {
        projects_indexed: projects_indexed,
        projects_total: projects_total,
        total_artifacts: total_artifacts,
        stale_artifacts: stale_artifacts,
        stale_percent: stale_percent,
        artifacts_by_type: artifacts_by_type,
        last_collection_at: last_collection_at,
        provider_health: provider_health,
        operational_status: operational_status,
        pipeline_metrics: pipeline_metrics,
        token_usage_summary: token_usage_summary,
        knowledge_usage_summary: knowledge_usage_summary,
        usage_by_goal: usage_by_goal
      }
    end

    private

    def artifacts
      @artifacts ||= KnowledgeArtifact
        .joins(:project)
        .where(projects: { account_id: account.id })
    end

    def projects_total
      @projects_total ||= Project.where(account_id: account.id).count
    end

    def projects_indexed
      @projects_indexed ||= artifacts.where.not(status: "deleted")
        .select(:project_id).distinct.count
    end

    def total_artifacts
      @total_artifacts ||= artifacts.active.count
    end

    def stale_artifacts
      @stale_artifacts ||= artifacts.stale.count
    end

    def stale_percent
      total = total_artifacts + stale_artifacts
      return 0 if total.zero?

      ((stale_artifacts.to_f / total) * 100).round
    end

    def artifacts_by_type
      @artifacts_by_type ||= artifacts.active.group(:artifact_type).count
        .sort_by { |_, v| -v }
    end

    def last_collection_at
      @last_collection_at ||= CollectorRun
        .joins(project_version: :project)
        .where(projects: { account_id: account.id })
        .where(status: "completed")
        .maximum(:completed_at)
    end

    def token_usage_summary
      @token_usage_summary ||= knowledge_runs
        .group(:operation_type)
        .pluck(
          Arel.sql("operation_type"),
          Arel.sql("SUM(total_tokens)"),
          Arel.sql("COUNT(*)")
        )
        .map { |op, tokens, count| { operation_type: op, total_tokens: tokens.to_i, run_count: count.to_i } }
    end

    def knowledge_runs
      KnowledgeRun.joins(:project)
        .where(projects: { account_id: account.id })
    end

    def provider_health
      @provider_health ||= Rails.cache.fetch(provider_health_cache_key, expires_in: CACHE_TTL) do
        build_provider_health
      end
    end

    def operational_status
      return "healthy" if provider_health[:embedding_available] && provider_health[:chat_available]
      return "degraded" if provider_health[:embedding_available] || provider_health[:chat_available]

      "unavailable"
    end

    def pipeline_metrics
      @pipeline_metrics ||= Rails.cache.fetch(pipeline_metrics_cache_key, expires_in: CACHE_TTL) do
        build_pipeline_metrics
      end
    end

    def knowledge_usage_summary
      @knowledge_usage_summary ||= KnowledgeUsageStat
        .joins(:project)
        .where(projects: { account_id: account.id })
        .group(:artifact_type)
        .sum(:artifact_count)
        .sort_by { |_, v| -v }
    end

    def usage_by_goal
      @usage_by_goal ||= KnowledgeUsageStat
        .joins(:project)
        .where(projects: { account_id: account.id })
        .group(:goal)
        .sum(:artifact_count)
        .sort_by { |_, v| -v }
    end

    def provider_health_cache_key
      [
        "knowledge/dashboard_stats/provider_health",
        account.id,
        owner&.id || "none",
        user_setting&.updated_at&.to_i || "none"
      ].join("/")
    end

    def build_provider_health
      return empty_provider_health unless user_setting && owner

      embedding_providers = configured_providers_for(:embedding)
      chat_providers = configured_providers_for(:chat)
      provider_states = owner.provider_states
        .where(provider_name: (embedding_providers + chat_providers).uniq)
        .index_by(&:provider_name)

      embedding = embedding_providers.map { |provider| provider_status(provider, provider_states) }
      chat = chat_providers.map { |provider| provider_status(provider, provider_states) }

      {
        embedding: embedding,
        chat: chat,
        embedding_available: embedding.any? { |provider| provider[:available] },
        chat_available: chat.any? { |provider| provider[:available] }
      }
    end

    def empty_provider_health
      {
        embedding: [],
        chat: [],
        embedding_available: false,
        chat_available: false
      }
    end

    def configured_providers_for(operation)
      return [] unless user_setting

      providers =
        case operation.to_sym
        when :embedding
          [ user_setting.kb_embedding_provider, *Array(user_setting.kb_embedding_fallback_providers) ]
        when :chat
          [ user_setting.kb_chat_provider, *Array(user_setting.kb_chat_fallback_providers) ]
        else
          []
        end

      providers.filter_map { |provider| provider.to_s.strip.downcase.presence }
        .uniq
        .select { |provider| supported_providers_for(operation).include?(provider) }
    end

    def supported_providers_for(operation)
      case operation.to_sym
      when :embedding
        UserSetting::KB_EMBEDDING_PROVIDERS
      when :chat
        UserSetting::KB_CHAT_PROVIDERS
      else
        []
      end
    end

    def provider_status(provider, provider_states)
      state = provider_states[provider]
      state.check_circuit_recovery!(timeout: user_setting.circuit_breaker_timeout_seconds) if state

      {
        provider: provider,
        circuit_state: state&.circuit_state || "closed",
        rate_limited: state&.rate_limited? || false,
        rate_limited_until: state&.rate_limited_until,
        recent_failures: state&.failure_count || 0,
        available: state.nil? || !state.unavailable?
      }
    end

    def pipeline_metrics_cache_key
      relation = knowledge_runs.where(created_at: PIPELINE_LOOKBACK.ago..Time.current)
      [
        "knowledge/dashboard_stats/pipeline_metrics",
        account.id,
        relation.maximum(:updated_at)&.to_i || "none",
        relation.count
      ].join("/")
    end

    def build_pipeline_metrics
      operation_summaries = pipeline_operation_summaries.index_by { |summary| summary[:operation_type] }
      distributions = pipeline_provider_distribution.group_by { |summary| summary[:operation_type] }

      KnowledgeRun::OPERATION_TYPES.index_with do |operation_type|
        summary = operation_summaries[operation_type]
        provider_distribution = Array(distributions[operation_type]).sort_by { |provider| [ -provider[:run_count], provider[:provider] ] }

        {
          lookback_days: PIPELINE_LOOKBACK / 1.day,
          total_runs: summary&.fetch(:total_runs, 0) || 0,
          finished_runs: summary&.fetch(:finished_runs, 0) || 0,
          successful_runs: summary&.fetch(:successful_runs, 0) || 0,
          failed_runs: summary&.fetch(:failed_runs, 0) || 0,
          success_rate: summary&.fetch(:success_rate, 0.0) || 0.0,
          avg_duration_seconds: summary&.fetch(:avg_duration_seconds, 0.0) || 0.0,
          provider_distribution: provider_distribution
        }
      end
    end

    def pipeline_operation_summaries
      pipeline_runs
        .group(:operation_type)
        .pluck(
          Arel.sql("knowledge_runs.operation_type"),
          Arel.sql("COUNT(*)"),
          Arel.sql("COUNT(*) FILTER (WHERE knowledge_runs.status IN (#{FINISHED_STATUSES_SQL}))"),
          Arel.sql("COUNT(*) FILTER (WHERE knowledge_runs.status = 'completed')"),
          Arel.sql("COUNT(*) FILTER (WHERE knowledge_runs.status = 'failed')"),
          Arel.sql("AVG(EXTRACT(EPOCH FROM (knowledge_runs.updated_at - knowledge_runs.created_at))) FILTER (WHERE knowledge_runs.status IN (#{FINISHED_STATUSES_SQL}))")
        )
        .map do |operation_type, total_runs, finished_runs, successful_runs, failed_runs, avg_duration_seconds|
          {
            operation_type: operation_type,
            total_runs: total_runs,
            finished_runs: finished_runs,
            successful_runs: successful_runs,
            failed_runs: failed_runs,
            success_rate: percentage(successful_runs, finished_runs),
            avg_duration_seconds: avg_duration_seconds.to_f.round(2)
          }
        end
    end

    def pipeline_provider_distribution
      pipeline_runs
        .group(:operation_type, Arel.sql(effective_provider_sql))
        .pluck(
          Arel.sql("knowledge_runs.operation_type"),
          Arel.sql("#{effective_provider_sql}"),
          Arel.sql("COUNT(*)"),
          Arel.sql("COUNT(*) FILTER (WHERE knowledge_runs.status IN (#{FINISHED_STATUSES_SQL}))"),
          Arel.sql("COUNT(*) FILTER (WHERE knowledge_runs.status = 'completed')"),
          Arel.sql("AVG(EXTRACT(EPOCH FROM (knowledge_runs.updated_at - knowledge_runs.created_at))) FILTER (WHERE knowledge_runs.status IN (#{FINISHED_STATUSES_SQL}))")
        )
        .map do |operation_type, provider, run_count, finished_runs, successful_runs, avg_duration_seconds|
          {
            operation_type: operation_type,
            provider: provider,
            run_count: run_count,
            success_rate: percentage(successful_runs, finished_runs),
            avg_duration_seconds: avg_duration_seconds.to_f.round(2)
          }
        end
    end

    def pipeline_runs
      knowledge_runs.where(created_at: PIPELINE_LOOKBACK.ago..Time.current)
    end

    def effective_provider_sql
      <<~SQL.squish
        COALESCE(
          NULLIF(final_provider, ''),
          CASE
            WHEN jsonb_array_length(COALESCE(provider_attempts, '[]'::jsonb)) > 0
              THEN COALESCE(provider_attempts, '[]'::jsonb) -> (jsonb_array_length(COALESCE(provider_attempts, '[]'::jsonb)) - 1) ->> 'provider'
          END,
          'unknown'
        )
      SQL
    end

    def percentage(numerator, denominator)
      return 0.0 if denominator.zero?

      ((numerator.to_f / denominator) * 100).round(1)
    end

    def owner
      @owner ||= account.fallback_owner
    end

    def user_setting
      @user_setting ||= owner&.settings
    end
  end
end
