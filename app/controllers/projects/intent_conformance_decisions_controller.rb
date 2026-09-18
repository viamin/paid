# frozen_string_literal: true

module Projects
  # Records a human's resolution of a blocked RDR-067 intent-conformance
  # verdict from the Inbox: fix PR, a bounded exception, or a design
  # amendment. See docs/intent/approved-intent-conformance/.
  #
  # @spec INTENT-CONFORMANCE-004
  class IntentConformanceDecisionsController < ApplicationController
    before_action :authenticate_user!
    before_action :set_project

    def create
      authorize @project, :run_agent?

      verdict = resolve_verdict
      unless verdict
        redirect_to safe_return_target || dashboard_path, alert: "Please select an intent-conformance decision."
        return
      end

      result = IntentConformance::RecordDecision.call(
        verdict: verdict, action: params[:action_type], reason: params[:reason], actor: current_user
      )

      redirect_to safe_return_target || dashboard_path, **decision_flash(result, verdict)
    end

    private

    def set_project
      @project = policy_scope(Project).find(params[:project_id])
    end

    def resolve_verdict
      return nil if params[:verdict_id].blank?

      IntentConformanceVerdict.joins(:issue).where(issues: { project_id: @project.id }).find_by(id: params[:verdict_id])
    end

    def decision_flash(result, verdict)
      pr_ref = "#{@project.full_name}##{verdict.issue.github_number}"
      return { notice: "Decision recorded for PR #{pr_ref}." } if result.success?

      { alert: "Could not record the decision for PR #{pr_ref}: #{result.error}" }
    end

    def safe_return_target
      normalized_return_to(params[:return_to])
    end
  end
end
