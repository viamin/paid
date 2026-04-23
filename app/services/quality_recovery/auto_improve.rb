# frozen_string_literal: true

module QualityRecovery
  class AutoImprove
    MAX_CYCLES_PER_DAY = 3
    EVALUATION_RUNS = QualityThreshold::DEFAULT_WINDOW_SIZE

    def self.call(...)
      new(...).call
    end

    def initialize(agent_run:, breach:)
      @agent_run = agent_run
      @project = agent_run.project
      @breach = breach
    end

    def call
      return if active_recovery?

      if monitor_action(latest_action("model_escalation"))
        return
      elsif monitor_action(latest_action("prompt_evolution"))
        return
      end

      if latest_action("prompt_evolution").blank?
        start_prompt_evolution
      elsif latest_action("model_escalation").blank?
        escalate_model
      else
        pause_project
      end
    end

    private

    attr_reader :agent_run, :project, :breach

    def active_recovery?
      project.quality_recovery_actions
        .where(action_type: %w[prompt_evolution model_escalation], status: %w[pending executing])
        .exists?
    end

    def monitor_action(action)
      return false unless action&.status == "executed"

      scores = scores_after(action.executed_at)
      return true if scores.size < EVALUATION_RUNS

      average = (scores.sum / scores.size).round(4)
      action.evaluate!(average)
      return true unless breach.fetch(:threshold).breached?(average)

      false
    end

    def start_prompt_evolution
      return pause_project if cooldown_exhausted?

      prompt = recovery_prompt
      return escalate_model unless prompt

      action = create_action("prompt_evolution", prompt: prompt, executed_at: nil)
      PromptEvolutionJob.perform_later(
        project_id: project.id,
        prompt_id: prompt.id,
        recovery_action_id: action.id
      )
      action.update!(result: { status: "queued", prompt_id: prompt.id })

      Rails.logger.info(
        message: "quality_recovery.prompt_evolution_queued",
        project_id: project.id,
        recovery_action_id: action.id,
        prompt_id: prompt.id,
        agent_run_id: agent_run.id
      )
    end

    def escalate_model
      return pause_project if cooldown_exhausted?

      from_tier = current_tier
      to_tier = next_tier(from_tier)
      return pause_project unless to_tier

      preferences = project.model_preferences.deep_dup
      preferences["quality_recovery_min_tier"] = to_tier
      project.update!(model_preferences: preferences)

      action = create_action("model_escalation", parameters: { from_tier: from_tier, to_tier: to_tier })
      action.complete!(status: "escalated", from_tier: from_tier, to_tier: to_tier)

      Rails.logger.info(
        message: "quality_recovery.model_escalated",
        project_id: project.id,
        recovery_action_id: action.id,
        from_tier: from_tier,
        to_tier: to_tier,
        agent_run_id: agent_run.id
      )
    end

    def pause_project
      return if project.quality_paused?

      action = create_action("final_pause")
      project.quality_pause!(
        score: breach.fetch(:average),
        threshold: breach.fetch(:threshold).min_value,
        agent_run: agent_run,
        metadata: pause_metadata.merge(recovery_action_id: action.id)
      )
      action.complete!(status: "paused")
      publish_pause_alert(action)

      Rails.logger.warn(
        message: "quality_recovery.final_pause",
        project_id: project.id,
        recovery_action_id: action.id,
        metric_type: breach.fetch(:threshold).metric_type,
        goal_type: agent_run.goal,
        rolling_average: breach.fetch(:average),
        threshold: breach.fetch(:threshold).min_value,
        agent_run_id: agent_run.id
      )
    end

    def publish_pause_alert(action)
      Notifications::Publish.call(
        account: project.account,
        source: "quality_recovery",
        subject: project,
        severity: :error,
        title: "Quality recovery failed for #{project.name}",
        description: "Automatic runs were paused after prompt evolution and model escalation did not restore quality.",
        metadata: pause_metadata.merge(
          recovery_action_id: action.id,
          diagnosis: diagnosis
        ),
        action_url: "/projects/#{project.id}/edit",
        nav_section: "projects"
      )
    end

    def create_action(action_type, prompt: nil, parameters: {}, executed_at: Time.current)
      QualityRecoveryAction.create!(
        project: project,
        agent_run: agent_run,
        prompt_version: prompt&.current_version,
        action_type: action_type,
        diagnosis: diagnosis,
        parameters: parameters.presence || action_parameters,
        quality_before: breach.fetch(:average),
        status: "executing",
        executed_at: executed_at
      )
    end

    def diagnosis
      {
        "metric_type" => breach.fetch(:threshold).metric_type,
        "goal_type" => agent_run.goal,
        "threshold" => breach.fetch(:threshold).min_value,
        "rolling_average" => breach.fetch(:average),
        "sample_size" => breach.fetch(:sample_size)
      }
    end

    def action_parameters
      {
        metric_type: breach.fetch(:threshold).metric_type,
        goal_type: agent_run.goal,
        recent_scores: breach.fetch(:scores)
      }
    end

    def pause_metadata
      {
        metric_type: breach.fetch(:threshold).metric_type,
        goal_type: agent_run.goal,
        window_size: QualityThreshold::DEFAULT_WINDOW_SIZE,
        sample_size: breach.fetch(:sample_size),
        recent_scores: breach.fetch(:scores),
        recovery_attempts: project.quality_recovery_actions.recent.limit(10).pluck(:action_type, :status)
      }
    end

    def recovery_prompt
      return agent_run.prompt_version.prompt if agent_run.prompt_version&.prompt

      metric = recent_metrics.first
      metric&.prompt_version&.prompt
    end

    def latest_action(action_type)
      project.quality_recovery_actions
        .where(action_type: action_type)
        .recent
        .first
    end

    def scores_after(timestamp)
      metric_scope.where("quality_metrics.created_at > ?", timestamp)
        .limit(EVALUATION_RUNS)
        .filter_map { |metric| score_for(metric) }
    end

    def recent_metrics
      @recent_metrics ||= metric_scope.limit(EVALUATION_RUNS).includes(prompt_version: :prompt).to_a
    end

    def metric_scope
      scope = QualityMetric.by_project(project.id)
        .where(agent_runs: { goal: agent_run.goal })
        .where(AgentRun.quality_scoreable_sql)
        .order(created_at: :desc)

      if metric_type == "composite_score"
        scope.where.not(composite_score: nil)
      else
        scope.where("jsonb_exists(quality_metrics.scores, ?)", metric_type)
      end
    end

    def score_for(metric)
      if metric_type == "composite_score"
        metric.composite_score&.to_f
      else
        metric.scores&.dig(metric_type)&.to_f
      end
    end

    def metric_type
      breach.fetch(:threshold).metric_type
    end

    def cooldown_exhausted?
      project.quality_recovery_actions
        .where(action_type: "prompt_evolution", created_at: 24.hours.ago..)
        .count >= MAX_CYCLES_PER_DAY
    end

    def current_tier
      agent_run.model_selection&.tier ||
        project.agent_runs.joins(:model_selection).order(Arel.sql("model_selections.created_at DESC")).pick("model_selections.tier") ||
        "low"
    end

    def next_tier(tier)
      current_index = LlmModel::TIERS.index(tier) || 0
      LlmModel::TIERS[current_index + 1]
    end
  end
end
