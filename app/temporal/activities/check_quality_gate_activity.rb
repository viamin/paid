# frozen_string_literal: true

module Activities
  class CheckQualityGateActivity < BaseActivity
    activity_name "CheckQualityGate"

    DEFAULT_WINDOW_SIZE = 5
    DEFAULT_MIN_RECENT_RUNS = 3
    PR_AUTO_CONTINUE_TOKEN_LIMIT_REASON = "pr_auto_continue_token_limit_exceeded"

    def execute(input)
      @project = Project.find(input[:project_id])
      @agent_run = input[:agent_run_id] ? AgentRun.find_by(id: input[:agent_run_id]) : nil
      @issue = input[:issue_id] ? Issue.find_by(id: input[:issue_id]) : nil
      @source_pull_request_number = input[:source_pull_request_number]
      @source_pull_request = nil
      @settings = nil

      result = evaluate(input)
      record_workflow_state(input, result)
      log_result(result, input)

      result
    end

    private

    attr_reader :project, :agent_run, :issue, :source_pull_request_number

    def evaluate(input) # @spec QUALITY-LOOPS-005
      bypass = bypass_reason(input)
      return allowed_result(reason: bypass, bypassed: true) if bypass && bypass != "priority_run"

      token_limit_result = pr_auto_continue_token_limit_result
      return token_limit_result if token_limit_result

      return allowed_result(reason: "priority_run", bypassed: true) if bypass == "priority_run"
      return allowed_result(reason: "quality_gates_disabled") unless project.quality_gates_enabled?

      metrics = recent_metrics
      return insufficient_data_result(metrics.size) if metrics.size < min_recent_runs

      breaches = detect_breaches(metrics)
      return recovery_result(breaches, metrics.size) if recovery_bypass?(breaches)

      {
        allowed: breaches.empty?,
        blocked: breaches.any?,
        bypassed: false,
        reason: breaches.any? ? "quality_gate_breached" : "quality_gate_passed",
        breaches: breaches,
        sample_size: metrics.size,
        window_size: window_size,
        evaluated_at: Time.current.iso8601
      }
    end

    def bypass_reason(input)
      return "explicit_bypass" if input[:bypass_quality_gate]
      return "manual_run" if agent_run&.manual?

      "priority_run" if priority_run?
    end

    def priority_run?
      agent_run&.priority_tier.present? ||
        agent_run&.label_priority_tier.present? ||
        priority_issue? ||
        priority_pr?
    end

    def priority_issue?
      labels = Array(issue&.labels)
      labels.intersect?(project.priority_label_names)
    end

    def priority_pr?
      return false if source_pull_request_number.blank?

      labels = Array(source_pull_request&.labels)
      labels.intersect?(project.priority_label_names)
    end

    # @spec FOCUSED-RUN-007
    def pr_auto_continue_token_limit_result
      return if source_pull_request_number.blank?
      return if source_pull_request&.pr_auto_continue_token_limit_overridden_at.present?

      limit = project.max_pr_auto_continue_tokens.to_i
      used = pr_auto_continue_tokens_used
      return if used < limit

      {
        allowed: false,
        blocked: true,
        bypassed: false,
        reason: PR_AUTO_CONTINUE_TOKEN_LIMIT_REASON,
        issue_id: source_pull_request&.id,
        breaches: [
          breach_hash(
            metric: "pr_auto_continue_tokens",
            current: used,
            threshold: limit,
            severity: "critical"
          )
        ],
        evaluated_at: Time.current.iso8601
      }
    end

    def pr_auto_continue_tokens_used
      AgentRun.pr_auto_continue_tokens_used(
        project: project,
        pr_number: source_pull_request_number,
        issue: source_pull_request
      )
    end

    def source_pull_request
      @source_pull_request ||= project.issues.find_by(
        github_number: source_pull_request_number,
        is_pull_request: true
      )
    end

    def recent_metrics
      QualityMetric
        .by_project(project.id)
        .automated
        .with_composite_score
        .order(created_at: :desc)
        .limit(window_size)
        .to_a
    end

    def detect_breaches(metrics)
      setting_breaches(metrics) + threshold_breaches(metrics)
    end

    def recovery_bypass?(breaches)
      breaches.any? &&
        breaches.all? { |breach| breach[:metric] == "composite_score" } &&
        QualityRecovery::ModelEscalation.active?(project)
    end

    def setting_breaches(metrics)
      breaches = []
      composite_average = average(metrics.map { |metric| metric.composite_score.to_f })

      if composite_average && composite_average < composite_score_threshold
        breaches << breach_hash(
          metric: "composite_score",
          current: composite_average,
          threshold: composite_score_threshold,
          severity: "critical"
        )
      end

      metric_thresholds.each do |metric_key, threshold|
        metric_average = average(metrics.filter_map { |metric| metric.scores&.dig(metric_key)&.to_f })
        next unless metric_average && metric_average < threshold.to_f

        breaches << breach_hash(
          metric: metric_key,
          current: metric_average,
          threshold: threshold.to_f,
          severity: "warning"
        )
      end

      breaches
    end

    def threshold_breaches(metrics)
      project.quality_gate_thresholds.enabled.filter_map do |threshold|
        score = average(score_values(metrics, threshold.metric_key))
        next unless threshold.breached?(score)

        breach_hash(
          metric: threshold.metric_key,
          current: score,
          threshold: threshold.breached_value(score).to_f,
          severity: threshold.severity
        )
      end
    end

    def score_values(metrics, metric_key)
      if metric_key == "composite_score"
        metrics.map { |metric| metric.composite_score.to_f }
      else
        metrics.filter_map { |metric| metric.scores&.dig(metric_key)&.to_f }
      end
    end

    def average(values)
      return if values.empty?

      (values.sum / values.size).round(4)
    end

    def breach_hash(metric:, current:, threshold:, severity:)
      {
        metric: metric,
        current: current,
        threshold: threshold,
        severity: severity
      }
    end

    def record_workflow_state(input, result) # @spec QUALITY-LOOPS-005
      workflow_id = input[:workflow_id]
      return if workflow_id.blank?

      state = WorkflowState.find_or_initialize_by(temporal_workflow_id: workflow_id)
      state.assign_attributes(
        project: project,
        workflow_type: input[:workflow_type] || "AgentExecutionWorkflow",
        status: "running",
        started_at: state.started_at || Time.current,
        result_data: (state.result_data || {}).merge("quality_gate" => result.deep_stringify_keys)
      )
      state.save!
    end

    def log_result(result, input)
      logger.info(
        message: "quality_gate.checked",
        project_id: project.id,
        agent_run_id: agent_run&.id,
        issue_id: issue&.id || input[:issue_id],
        allowed: result[:allowed],
        reason: result[:reason],
        sample_size: result[:sample_size],
        breach_count: result.fetch(:breaches, []).size
      )
    end

    def allowed_result(reason:, bypassed: false)
      {
        allowed: true,
        blocked: false,
        bypassed: bypassed,
        reason: reason,
        breaches: [],
        sample_size: 0,
        window_size: window_size,
        evaluated_at: Time.current.iso8601
      }
    end

    def insufficient_data_result(sample_size)
      allowed_result(reason: "insufficient_data").merge(
        sample_size: sample_size,
        min_required: min_recent_runs
      )
    end

    def recovery_result(breaches, sample_size)
      allowed_result(reason: "quality_recovery_model_escalation_active").merge(
        breaches: breaches,
        sample_size: sample_size,
        recovery: QualityRecovery::ModelEscalation.state(project)
      )
    end

    def settings
      @settings ||= project.effective_quality_gate_settings
    end

    def window_size
      settings.fetch("rolling_window_size", DEFAULT_WINDOW_SIZE)
    end

    def min_recent_runs
      settings.fetch("min_recent_runs", DEFAULT_MIN_RECENT_RUNS)
    end

    def composite_score_threshold
      settings.fetch("composite_score_threshold", QualityAlerts::Evaluate::COMPOSITE_SCORE_THRESHOLD_DEFAULT).to_f
    end

    def metric_thresholds
      settings.fetch("metric_thresholds", {})
    end
  end
end
