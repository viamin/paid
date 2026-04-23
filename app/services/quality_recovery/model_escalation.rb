# frozen_string_literal: true

module QualityRecovery
  class ModelEscalation
    PREFERENCE_KEY = "quality_triggered_escalation"
    DEFAULT_EVALUATION_WINDOW = 3

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
      state(project)["status"] == "active"
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
      return result(started: false, defer_pause: true, reason: "already_active") if self.class.active?(project)
      return result(started: false, pause: true, reason: "no_higher_tier") unless target_model

      project.update!(model_preferences: preferences_with(escalation_state))
      record_action
      log_started

      result(started: true, defer_pause: true, reason: "model_escalation_started", state: escalation_state)
    end

    def evaluate
      return result(defer_pause: true, reason: "model_escalation_active") if samples.size < evaluation_window
      return result(defer_pause: true, reason: "model_escalation_improving") if escalated_average >= threshold

      request_prompt_evolution
      result(defer_pause: true, reason: "prompt_evolution_requested", state: prompt_evolution_state)
    end

    private

    attr_reader :project, :agent_run, :breach

    def result(started: false, defer_pause: false, pause: false, reason:, state: self.class.state(project))
      Result.new(started, defer_pause, pause, reason, state)
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

    def target_model
      @target_model ||= LlmModel.active.by_tier(to_tier).by_capability.first if to_tier
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

    def current_score
      breach&.fetch(:average, nil)
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
        .where(agent_runs: { goal: agent_run.goal })
        .where(model_selections: { selector_type: "quality_escalation", tier: self.class.target_tier(project) })
        .where("quality_metrics.created_at >= ?", started_at)
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

    def escalated_average
      samples.sum / samples.size
    end

    def request_prompt_evolution
      project.update!(model_preferences: preferences_with(prompt_evolution_state))
      PromptEvolutionJob.perform_later
      log_prompt_evolution_requested
    end

    def prompt_evolution_state
      self.class.state(project).merge(
        "status" => "prompt_evolution_requested",
        "prompt_evolution_requested_at" => Time.current.iso8601,
        "escalated_average" => escalated_average.round(4),
        "evaluated_sample_size" => samples.size
      )
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
        message: "model_selection.quality_escalation_exhausted",
        project_id: project.id,
        agent_run_id: agent_run&.id,
        to_tier: self.class.state(project)["to_tier"],
        escalated_average: escalated_average.round(4),
        threshold: threshold
      )
    end
  end
end
