# frozen_string_literal: true

module QualityRecovery
  # Executes a recovery action (prompt rollback, model change, config adjustment).
  # Creates a QualityRecoveryAction record, performs the action, and records the
  # pre-action quality score for later effectiveness evaluation.
  #
  # @example
  #   result = QualityRecovery::ExecuteAction.call(
  #     project: project,
  #     action_type: "prompt_rollback",
  #     parameters: { prompt_id: 1, to_version_id: 2 }
  #   )
  #   result.recovery_action # => QualityRecoveryAction
  class ExecuteAction
    def self.call(...)
      new(...).call
    end

    def initialize(project:, action_type:, parameters:)
      @project = project
      @action_type = action_type
      @parameters = parameters
    end

    def call
      quality_before = current_quality_score

      recovery_action = QualityRecoveryAction.create!(
        project: project,
        action_type: action_type,
        parameters: parameters,
        quality_before: quality_before,
        status: "executing",
        executed_at: Time.current
      )

      result = execute(recovery_action)
      recovery_action.complete!(result)
      auto_resume_result = auto_resume_after_action(recovery_action)

      log_action(recovery_action)

      Result.new(recovery_action: recovery_action, success: true, auto_resume_result: auto_resume_result)
    rescue => e
      recovery_action&.fail!(error_class: e.class.name, error_message: e.message)

      Rails.logger.error(
        message: "quality_recovery.execute_action_failed",
        project_id: project.id,
        action_type: action_type,
        error_class: e.class.name,
        error_message: e.message
      )

      Result.new(recovery_action: recovery_action, success: false, error: e.message)
    end

    private

    attr_reader :project, :action_type, :parameters

    def execute(recovery_action)
      case action_type
      when "prompt_rollback"
        execute_prompt_rollback(recovery_action)
      when "model_change"
        execute_model_change
      when "config_adjustment"
        execute_config_adjustment
      else
        { status: "no_action", reason: "Unknown action type: #{action_type}" }
      end
    end

    def execute_prompt_rollback(recovery_action)
      prompt = Prompt.find(parameters[:prompt_id])
      to_version = prompt.prompt_versions.find(parameters[:to_version_id])

      recovery_action.update!(prompt_version: to_version)
      prompt.update!(current_version: to_version)

      {
        status: "rolled_back",
        prompt_id: prompt.id,
        prompt_name: prompt.name,
        from_version_id: parameters[:from_version_id],
        to_version_id: to_version.id,
        to_version_number: to_version.version
      }
    end

    def execute_model_change
      from_type = parameters[:from_agent_type]
      to_type = parameters[:to_agent_type]

      {
        status: "recommended",
        from_agent_type: from_type,
        to_agent_type: to_type,
        note: "Model change recommended. Review and apply through project settings before resuming automatic work."
      }
    end

    def execute_config_adjustment
      {
        status: "recommended",
        adjustment_type: parameters[:adjustment_type],
        suggestions: parameters[:suggestions],
        note: "Configuration adjustment recommended. Review and apply through project settings."
      }
    end

    def current_quality_score
      trend = QualityMetrics::TrendAnalysis.call(project_id: project.id, window_size: 10)
      trend[:rolling_average]
    end

    def log_action(recovery_action)
      Rails.logger.info(
        message: "quality_recovery.action_executed",
        project_id: project.id,
        recovery_action_id: recovery_action.id,
        action_type: action_type,
        quality_before: recovery_action.quality_before&.to_f,
        status: recovery_action.status
      )
    end

    def auto_resume_after_action(recovery_action)
      return unless action_type == "prompt_rollback"

      QualityPause::AutoResume.call(
        project: project,
        reason: "quality_recovery_#{action_type}",
        metadata: {
          recovery_action_id: recovery_action.id,
          action_type: action_type
        }
      )
    rescue => e
      Rails.logger.error(
        message: "quality_recovery.auto_resume_failed",
        project_id: project.id,
        recovery_action_id: recovery_action.id,
        action_type: action_type,
        error_class: e.class.name,
        error_message: e.message
      )
      nil
    end

    class Result
      attr_reader :recovery_action, :error, :auto_resume_result

      def initialize(recovery_action:, success:, error: nil, auto_resume_result: nil)
        @recovery_action = recovery_action
        @success = success
        @error = error
        @auto_resume_result = auto_resume_result
      end

      def success?
        @success
      end
    end
  end
end
