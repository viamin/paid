# frozen_string_literal: true

module Knowledge
  class DashboardStats
    CACHE_TTL = 60.seconds
    PIPELINE_LOOKBACK = 30.days

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
      @pipeline_metrics ||= begin
        runs_by_operation = knowledge_runs.where(created_at: PIPELINE_LOOKBACK.ago..Time.current)
          .order(created_at: :desc)
          .to_a
          .group_by(&:operation_type)

        KnowledgeRun::OPERATION_TYPES.index_with do |operation_type|
          summarize_pipeline_runs(runs_by_operation.fetch(operation_type, []))
        end
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

      {
        embedding: embedding_providers.map { |provider| provider_status(provider, provider_states) },
        chat: chat_providers.map { |provider| provider_status(provider, provider_states) },
        embedding_available: embedding_providers.any? { |provider| provider_available?(provider, provider_states) },
        chat_available: chat_providers.any? { |provider| provider_available?(provider, provider_states) }
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

    def provider_available?(provider, provider_states)
      provider_status(provider, provider_states)[:available]
    end

    def summarize_pipeline_runs(runs)
      finished_runs = runs.select { |run| KnowledgeRun::FINISHED_STATUSES.include?(run.status) }
      successful_runs = finished_runs.count { |run| run.status == "completed" }
      failed_runs = finished_runs.count { |run| run.status == "failed" }

      {
        lookback_days: PIPELINE_LOOKBACK / 1.day,
        total_runs: runs.size,
        finished_runs: finished_runs.size,
        successful_runs: successful_runs,
        failed_runs: failed_runs,
        success_rate: percentage(successful_runs, finished_runs.size),
        avg_duration_seconds: average_duration(finished_runs),
        provider_distribution: summarize_provider_distribution(runs)
      }
    end

    def summarize_provider_distribution(runs)
      runs.group_by(&:effective_provider)
        .sort_by { |provider, provider_runs| [ -provider_runs.size, provider ] }
        .map do |provider, provider_runs|
          finished_runs = provider_runs.select { |run| KnowledgeRun::FINISHED_STATUSES.include?(run.status) }
          successful_runs = finished_runs.count { |run| run.status == "completed" }

          {
            provider: provider,
            run_count: provider_runs.size,
            success_rate: percentage(successful_runs, finished_runs.size),
            avg_duration_seconds: average_duration(finished_runs)
          }
        end
    end

    def average_duration(runs)
      return 0.0 if runs.empty?

      total_duration = runs.sum { |run| run.updated_at - run.created_at }
      (total_duration / runs.size).round(2)
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
