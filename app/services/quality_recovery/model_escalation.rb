# frozen_string_literal: true

module QualityRecovery
  class ModelEscalation
    PREFERENCE_KEY = "quality_triggered_escalation"
    DEFAULT_EVALUATION_WINDOW = 3
    RECOVERY_STATUSES = %w[active prompt_evolution_requested].freeze

    Result = Data.define(:started, :defer_pause, :pause, :reason, :state) do
      def started?
        started
      end

      def defer_pause?
        defer_pause
      end

      def pause?
        pause
      end
    end

    def self.start(...)
      new(...).start
    end

    def self.evaluate(...)
      new(...).evaluate
    end

    def self.active?(project)
      RECOVERY_STATUSES.include?(state(project)["status"])
    end

    def self.target_tier(project)
      state(project)["to_tier"] if active?(project)
    end

    def self.state(project)
      raw = project.model_preferences[PREFERENCE_KEY]
      raw.is_a?(Hash) ? raw : {}
    end

    def initialize(project:, agent_run: nil, breach: nil)
      @project = project
      @agent_run = agent_run
      @breach = breach
    end

    def start
      return result(started: false, pause: true, reason: "quality_recovery_exhausted") if exhausted?
      return result(started: false, defer_pause: true, reason: "already_active") if self.class.active?(project)
      return result(started: false, pause: true, reason: "no_higher_tier") unless to_tier

      project.update!(model_preferences: preferences_with(escalation_state))
      record_action
      log_started

      result(started: true, defer_pause: true, reason: "model_escalation_started", state: escalation_state)
    end

    def evaluate
      return evaluate_prompt_evolution if prompt_evolution_requested?
      return result(pause: true, reason: "quality_recovery_exhausted") if exhausted?
      return result(defer_pause: true, reason: self.class.state(project)["status"]) unless evaluating_escalated_model?
      return result(defer_pause: true, reason: "model_escalation_active") if samples.size < evaluation_window
      return recover!(via: "model_escalation", average: escalated_average, sample_size: samples.size) if escalated_average >= threshold

      request_prompt_evolution
    end

    private

    attr_reader :project, :agent_run, :breach

    def result(started: false, defer_pause: false, pause: false, reason:, state: self.class.state(project))
      Result.new(started, defer_pause, pause, reason, state)
    end

    def evaluating_escalated_model?
      self.class.state(project)["status"] == "active"
    end

    def prompt_evolution_requested?
      self.class.state(project)["status"] == "prompt_evolution_requested"
    end

    def exhausted?
      self.class.state(project)["status"] == "exhausted"
    end

    def evaluate_prompt_evolution
      return result(defer_pause: true, reason: "prompt_evolution_pending") if prompt_evolution_samples.size < evaluation_window
      return recover!(via: "prompt_evolution", average: prompt_evolution_average, sample_size: prompt_evolution_samples.size) if prompt_evolution_average >= threshold

      project.update!(model_preferences: preferences_with(exhausted_state))
      result(pause: true, reason: "quality_recovery_exhausted", state: exhausted_state)
    end

    def from_tier
      @from_tier ||= agent_run&.model_selection&.tier || recent_selection&.tier || "mid"
    end

    def to_tier
      @to_tier ||= begin
        index = LlmModel::TIERS.index(from_tier)
        LlmModel::TIERS[index + 1] if index
      end
    end

    def recent_selection
      ModelSelection
        .joins(:agent_run)
        .where(agent_runs: { project_id: project.id })
        .where.not(tier: nil)
        .order(created_at: :desc)
        .first
    end

    def escalation_state
      {
        "status" => "active",
        "trigger" => "quality_drop",
        "goal" => goal,
        "prompt_id" => prompt_id,
        "prompt_version_id" => prompt_version_id,
        "from_tier" => from_tier,
        "to_tier" => to_tier,
        "started_at" => Time.current.iso8601,
        "trigger_agent_run_id" => agent_run&.id,
        "trigger_score" => current_score,
        "threshold" => threshold,
        "evaluation_window" => evaluation_window
      }
    end

    def preferences_with(state)
      project.model_preferences.merge(PREFERENCE_KEY => state)
    end

    def goal
      @goal ||= agent_run&.goal || self.class.state(project)["goal"]
    end

    def current_score
      breach&.fetch(:average, nil)
    end

    def prompt_id
      agent_run&.prompt_version&.prompt_id || self.class.state(project)["prompt_id"] || recent_prompt_id
    end

    def prompt_version_id
      agent_run&.prompt_version_id || self.class.state(project)["prompt_version_id"]
    end

    def threshold
      breach&.dig(:threshold)&.min_value&.to_f ||
        self.class.state(project)["threshold"].to_f
    end

    def evaluation_window
      window = self.class.state(project)["evaluation_window"].presence
      window ? window.to_i : DEFAULT_EVALUATION_WINDOW
    end

    def samples
      @samples ||= QualityMetric
        .by_project(project.id)
        .joins(agent_run: :model_selection)
        .where(agent_runs: { goal: goal })
        .where(model_selections: { selector_type: "quality_escalation", tier: self.class.target_tier(project) })
        .where("quality_metrics.created_at >= ?", started_at)
        .order(created_at: :desc)
        .limit(evaluation_window)
        .pluck(:composite_score)
        .compact
        .map(&:to_f)
    end

    def prompt_evolution_samples
      @prompt_evolution_samples ||= QualityMetric
        .by_project(project.id)
        .joins(agent_run: :model_selection)
        .where(agent_runs: { goal: goal })
        .where(model_selections: { selector_type: "quality_escalation", tier: self.class.target_tier(project) })
        .where("quality_metrics.created_at >= ?", prompt_evolution_requested_at)
        .order(created_at: :desc)
        .limit(evaluation_window)
        .pluck(:composite_score)
        .compact
        .map(&:to_f)
    end

    def started_at
      Time.iso8601(self.class.state(project).fetch("started_at"))
    rescue ArgumentError, KeyError
      Time.current
    end

    def prompt_evolution_requested_at
      Time.iso8601(self.class.state(project).fetch("prompt_evolution_requested_at"))
    rescue ArgumentError, KeyError
      Time.current
    end

    def escalated_average
      return 0.0 if samples.empty?

      samples.sum / samples.size
    end

    def prompt_evolution_average
      return 0.0 if prompt_evolution_samples.empty?

      prompt_evolution_samples.sum / prompt_evolution_samples.size
    end

    def rounded_average(values)
      return nil if values.empty?

      (values.sum / values.size).round(4)
    end

    def request_prompt_evolution
      target_prompt_id = prompt_id
      unless target_prompt_id
        state = exhausted_state("no_prompt_for_targeted_evolution")
        project.update!(model_preferences: preferences_with(state))
        return result(pause: true, reason: "quality_recovery_exhausted", state:)
      end

      state = prompt_evolution_state
      project.update!(model_preferences: preferences_with(state))
      PromptEvolutionJob.perform_later(prompt_id: target_prompt_id, project_id: project.id)
      log_prompt_evolution_requested
      result(defer_pause: true, reason: "prompt_evolution_requested", state:)
    end

    def prompt_evolution_state
      self.class.state(project).merge(
        "status" => "prompt_evolution_requested",
        "prompt_evolution_requested_at" => Time.current.iso8601,
        "escalated_average" => escalated_average.round(4),
        "evaluated_sample_size" => samples.size
      )
    end

    def exhausted_state(reason = nil)
      self.class.state(project).merge(
        "status" => "exhausted",
        "exhausted_at" => Time.current.iso8601,
        "prompt_evolution_average" => rounded_average(prompt_evolution_samples),
        "prompt_evolution_sample_size" => prompt_evolution_samples.size
      ).tap do |state|
        state["exhausted_reason"] = reason if reason.present?
      end
    end

    def recovered_state(via:, average:, sample_size:)
      self.class.state(project).merge(
        "status" => "recovered",
        "recovered_at" => Time.current.iso8601,
        "recovered_via" => via,
        "recovered_average" => average.round(4),
        "recovered_sample_size" => sample_size
      )
    end

    def recover!(via:, average:, sample_size:)
      state = recovered_state(via:, average:, sample_size:)
      project.update!(model_preferences: preferences_with(state))
      result(defer_pause: true, reason: "#{via}_recovered", state:)
    end

    def recent_prompt_id
      QualityMetric
        .by_project(project.id)
        .joins(agent_run: :prompt_version)
        .where(agent_runs: { goal: goal })
        .where("quality_metrics.created_at >= ?", started_at)
        .order(created_at: :desc)
        .limit(evaluation_window)
        .pick("prompt_versions.prompt_id")
    end

    def record_action
      QualityRecoveryAction.create!(
        project: project,
        agent_run: agent_run,
        action_type: "model_change",
        status: "executed",
        parameters: escalation_state,
        quality_before: current_score,
        executed_at: Time.current,
        result: { status: "quality_triggered_escalation_started" }
      )
    end

    def log_started
      Rails.logger.info(
        message: "model_selection.quality_escalation_started",
        project_id: project.id,
        agent_run_id: agent_run&.id,
        from_tier: from_tier,
        to_tier: to_tier,
        threshold: threshold
      )
    end

    def log_prompt_evolution_requested
      Rails.logger.warn(
        message: "model_selection.prompt_evolution_requested",
        project_id: project.id,
        agent_run_id: agent_run&.id,
        to_tier: self.class.state(project)["to_tier"],
        escalated_average: escalated_average.round(4),
        threshold: threshold
      )
    end
  end
end
