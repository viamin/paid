# frozen_string_literal: true

class RemediationDecisionsController < ApplicationController
  def show
    @remediation_decision = policy_scope(RemediationDecision).find(params[:id])
    authorize @remediation_decision
  end
end
