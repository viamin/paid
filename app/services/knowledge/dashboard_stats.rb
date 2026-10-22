# frozen_string_literal: true

module Knowledge
  # @spec KNOWLEDGE-DASHBOARD-001 KNOWLEDGE-DASHBOARD-002
  class DashboardStats
    # @spec KNOWLEDGE-CURATED-005
    CACHE_TTL = 5.minutes
    PIPELINE_LOOKBACK = 30.days

    attr_reader :account

    def initialize(account:)
      @account = account
    end

    def self.call(...)
      new(...).call
    end

    def call
      build_stats
    end

    private

    def build_stats
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
        usage_by_goal: usage_by_goal,
        usage_by_lane: usage_by_lane
      }
    end

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

    def usage_by_lane
      @usage_by_lane ||= knowledge_usage_summary.each_with_object({ "curated" => 0, "derived" => 0 }) do |(type, count), lanes|
        lane = KnowledgeArtifact.curated_type?(type) ? "curated" : "derived"
        lanes[lane] += count
      end
    end

    def provider_health_cache_key
      [
        "knowledge/dashboard_stats/provider_health",
        account.id,
        account.projects.cache_key_with_version,
        AccountMembership.where(account_id: account.id).cache_key_with_version,
        UserSetting.joins(:user).where(users: { account_id: account.id }).cache_key_with_version,
        ProviderApiKey.joins(:user).where(users: { account_id: account.id }).cache_key_with_version,
        RunnerState.joins(:user).where(users: { account_id: account.id }).cache_key_with_version
      ].join("/")
    end

    def build_provider_health
      owners = project_owner_groups
      readiness_data = readiness_data_for(owners.map(&:first))
      embedding = owners.flat_map { |owner, count| runner_health(owner, count, :embedding, readiness_data) }
      chat = owners.flat_map { |owner, count| runner_health(owner, count, :chat, readiness_data) }

      {
        embedding: embedding,
        chat: chat,
        embedding_available: embedding.any? { |runner| runner[:available] },
        chat_available: chat.any? { |runner| runner[:available] },
        scope: "project_effective_owners",
        project_count: owners.sum(&:last),
        owner_count: owners.size
      }
    end

    def project_owner_groups
      created_by_ids = account.projects.pluck(:created_by_id)
      return [] if created_by_ids.empty?

      fallback_owner_id = account.fallback_owner_id
      owner_ids = created_by_ids.filter_map { |id| id || fallback_owner_id }
      owners = User.where(id: owner_ids.uniq).includes(:user_setting).index_by(&:id)

      owner_ids.tally.filter_map { |owner_id, count| [ owners[owner_id], count ] if owners.key?(owner_id) }
    end

    def readiness_data_for(owners)
      owner_ids = owners.map(&:id)

      {
        provider_api_keys: ProviderApiKey.where(user_id: owner_ids).group_by(&:user_id),
        runner_states: RunnerState.where(user_id: owner_ids).group_by(&:user_id).transform_values { |states| states.index_by(&:runner_name) }
      }
    end

    def runner_health(owner, project_count, operation, readiness_data)
      setting = owner.settings
      runners = configured_runners_for(setting, operation)
      states = readiness_data[:runner_states].fetch(owner.id, {})
      credential_availability = {
        provider_api_keys: readiness_data[:provider_api_keys].fetch(owner.id, [])
      }

      runners.map do |runner|
        readiness = RunnerReadiness.call(owner:, operation:, runner:, credential_availability:)
        runner_status(runner, states, readiness, owner).merge(owner_id: owner.id, project_count: project_count)
      end
    end

    def configured_runners_for(setting, operation)
      return [] unless setting

      runners =
        case operation.to_sym
        when :embedding
          [ setting.kb_embedding_runner, *Array(setting.kb_embedding_fallback_runners) ]
        when :chat
          [ setting.kb_chat_runner, *Array(setting.kb_chat_fallback_runners) ]
        else
          []
        end

      runners.filter_map { |runner| runner.to_s.strip.downcase.presence }
        .uniq
    end

    def runner_status(runner, runner_states, readiness, owner)
      state = runner_states[runner]
      state.check_circuit_recovery!(timeout: owner.settings.circuit_breaker_timeout_seconds) if state
      operational_status = operational_status_for(state)

      {
        runner: runner,
        circuit_state: state&.circuit_state || "closed",
        rate_limited: state&.rate_limited? || false,
        rate_limited_until: state&.rate_limited_until,
        recent_failures: state&.failure_count || 0,
        operational_status: operational_status,
        configuration_status: readiness.status,
        credential_source: readiness.credential_source,
        credential_service: readiness.credential_service,
        credential_name: readiness.credential_name,
        validated_with_provider: readiness.validated_with_provider,
        available: readiness.status == "ready" && operational_status != "unavailable"
      }
    end

    def operational_status_for(state)
      return "unavailable" if state&.unavailable?
      return "degraded" if state&.failure_count.to_i.positive?

      "healthy"
    end

    def pipeline_metrics_cache_key
      [
        "knowledge/dashboard_stats/pipeline_metrics",
        account.id
      ].join("/")
    end

    def build_pipeline_metrics
      operation_summaries = pipeline_operation_summaries.index_by { |summary| summary[:operation_type] }
      distributions = pipeline_runner_distribution.group_by { |summary| summary[:operation_type] }

      KnowledgeRun::OPERATION_TYPES.index_with do |operation_type|
        summary = operation_summaries[operation_type]
        runner_distribution = Array(distributions[operation_type]).sort_by { |runner| [ -runner[:run_count], runner[:runner] ] }

        {
          lookback_days: PIPELINE_LOOKBACK / 1.day,
          total_runs: summary&.fetch(:total_runs, 0) || 0,
          finished_runs: summary&.fetch(:finished_runs, 0) || 0,
          successful_runs: summary&.fetch(:successful_runs, 0) || 0,
          failed_runs: summary&.fetch(:failed_runs, 0) || 0,
          success_rate: summary&.fetch(:success_rate, 0.0) || 0.0,
          avg_duration_seconds: summary&.fetch(:avg_duration_seconds, 0.0) || 0.0,
          runner_distribution: runner_distribution
        }
      end
    end

    def pipeline_operation_summaries
      pipeline_runs
        .group(:operation_type)
        .pluck(
          Arel.sql("knowledge_runs.operation_type"),
          Arel.sql("COUNT(*)"),
          Arel.sql("COUNT(*)"),
          Arel.sql("COUNT(*) FILTER (WHERE knowledge_runs.status = 'completed')"),
          Arel.sql("COUNT(*) FILTER (WHERE knowledge_runs.status = 'failed')"),
          Arel.sql("AVG(EXTRACT(EPOCH FROM (knowledge_runs.updated_at - knowledge_runs.created_at)))")
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

    def pipeline_runner_distribution
      pipeline_runs
        .group(:operation_type, Arel.sql(effective_provider_sql))
        .pluck(
          Arel.sql("knowledge_runs.operation_type"),
          Arel.sql("#{effective_provider_sql}"),
          Arel.sql("COUNT(*)"),
          Arel.sql("COUNT(*)"),
          Arel.sql("COUNT(*) FILTER (WHERE knowledge_runs.status = 'completed')"),
          Arel.sql("AVG(EXTRACT(EPOCH FROM (knowledge_runs.updated_at - knowledge_runs.created_at)))")
        )
        .map do |operation_type, runner, run_count, finished_runs, successful_runs, avg_duration_seconds|
          {
            operation_type: operation_type,
            runner: runner,
            run_count: run_count,
            success_rate: percentage(successful_runs, finished_runs),
            avg_duration_seconds: avg_duration_seconds.to_f.round(2)
          }
        end
    end

    def pipeline_runs
      knowledge_runs.finished.where(created_at: PIPELINE_LOOKBACK.ago..Time.current)
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
  end
end
