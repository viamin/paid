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

  # @spec RUN-OBSTACLE-003
  def dismiss
    @remediation_decision = policy_scope(RemediationDecision).find(params[:id])
    authorize @remediation_decision, :update?

    unless @remediation_decision.dismissable?
      redirect_to remediation_decision_path(@remediation_decision), alert: "Only proposed remediations can be dismissed."
      return
    end

    @remediation_decision.dismiss!(reason: params[:dismissal_reason])
    redirect_to remediation_decision_path(@remediation_decision), notice: "Proposal dismissed."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to remediation_decision_path(@remediation_decision), alert: e.record.errors.full_messages.to_sentence
  end
end
