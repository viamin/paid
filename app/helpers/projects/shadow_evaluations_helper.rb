# frozen_string_literal: true

module Projects
  # View vocabulary for the shadow-evaluation execution lifecycle (#4642).
  module ShadowEvaluationsHelper
    # The enqueue action doubles as retry/resume: re-running only spends on
    # cases without an evaluated verdict.
    # @spec INTENT-CONFORMANCE-ROLLOUT-011
    def execute_label(evaluation)
      case evaluation.status
      when "frozen" then "Execute reviewer now"
      when "cancelled" then "Resume reviewer execution"
      else "Retry not-evaluated cases"
      end
    end

    # Inbox-item execution state vocabulary (#4642): durable lifecycle the
    # operator can leave the page on and come back to.
    # @spec INTENT-CONFORMANCE-ROLLOUT-009
    # @spec INTENT-CONFORMANCE-ROLLOUT-011
    def inbox_execution_state_text(evaluation)
      case evaluation.status
      when "completed" then "reviewer execution completed"
      when "partial" then "reviewer execution partially completed — retry not-evaluated cases from the evaluation screen"
      when "cancelled" then "reviewer execution cancelled — collected evidence preserved; resume from the evaluation screen"
      else "reviewer execution failed — retry from the evaluation screen"
      end
    end
  end
end
