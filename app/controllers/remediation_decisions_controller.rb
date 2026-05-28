# frozen_string_literal: true

class RemediationDecisionsController < ApplicationController
  def show
    @remediation_decision = policy_scope(RemediationDecision).find(params[:id])
    authorize @remediation_decision
  end

  def revert
    @remediation_decision = policy_scope(RemediationDecision).find(params[:id])
    authorize @remediation_decision, :update?

    unless @remediation_decision.revertable?
      redirect_to remediation_decision_path(@remediation_decision), alert: "This remediation cannot be reverted."
      return
    end

    RevertRemediationDecisionJob.perform_later(@remediation_decision.id, actor_id: current_user.id)
    redirect_to remediation_decision_path(@remediation_decision), notice: "Revert queued."
  end
end
