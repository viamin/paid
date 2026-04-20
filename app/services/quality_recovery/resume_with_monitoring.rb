# frozen_string_literal: true

module QualityRecovery
  # Implements "resume with monitoring" mode: resumes paused agent runs one at a
  # time and evaluates quality after each run completes. If quality stabilizes
  # (meets threshold for a consecutive window), monitoring mode ends. If quality
  # remains poor, it pauses again and reports back.
  #
  # @example
  #   result = QualityRecovery::ResumeWithMonitoring.call(
  #     project: project,
  #     quality_threshold: 0.7,
  #     evaluation_window: 5
  #   )
  #   result.recovery_action  # => QualityRecoveryAction
  #   result.resumed_run      # => AgentRun (or nil)
  class ResumeWithMonitoring
    DEFAULT_QUALITY_THRESHOLD = 0.7
    DEFAULT_EVALUATION_WINDOW = 5

    def self.call(...)
      new(...).call
    end

    def initialize(project:, quality_threshold: DEFAULT_QUALITY_THRESHOLD, evaluation_window: DEFAULT_EVALUATION_WINDOW)
      @project = project
      @quality_threshold = quality_threshold
      @evaluation_window = evaluation_window
    end

    def call
      diagnosis = QualityRecovery::Diagnose.call(project: project)
      quality_before = current_quality_score

      recovery_action = QualityRecoveryAction.create!(
        project: project,
        action_type: "resume_with_monitoring",
        diagnosis: diagnosis,
        parameters: {
          quality_threshold: quality_threshold,
          evaluation_window: evaluation_window
        },
        quality_before: quality_before,
        status: "executing",
        executed_at: Time.current
      )

      paused_run = find_paused_run
      unless paused_run
        recovery_action.complete!(status: "no_paused_runs")
        return Result.new(recovery_action: recovery_action, resumed_run: nil)
      end

      paused_run.resume!
      recovery_action.update!(agent_run: paused_run)
      recovery_action.complete!(
        status: "resumed",
        agent_run_id: paused_run.id,
        monitoring: {
          quality_threshold: quality_threshold,
          evaluation_window: evaluation_window,
          resumed_at: Time.current.iso8601
        }
      )

      log_resume(recovery_action, paused_run)

      Result.new(recovery_action: recovery_action, resumed_run: paused_run)
    end

    private

    attr_reader :project, :quality_threshold, :evaluation_window

    def find_paused_run
      project.agent_runs
        .where(status: "paused")
        .order(paused_at: :asc)
        .first
    end

    def current_quality_score
      trend = QualityMetrics::TrendAnalysis.call(project_id: project.id, window_size: evaluation_window)
      trend[:rolling_average]
    end

    def log_resume(recovery_action, paused_run)
      Rails.logger.info(
        message: "quality_recovery.resume_with_monitoring",
        project_id: project.id,
        recovery_action_id: recovery_action.id,
        agent_run_id: paused_run.id,
        quality_threshold: quality_threshold,
        quality_before: recovery_action.quality_before&.to_f
      )
    end

    class Result
      attr_reader :recovery_action, :resumed_run

      def initialize(recovery_action:, resumed_run:)
        @recovery_action = recovery_action
        @resumed_run = resumed_run
      end
    end
  end
end
