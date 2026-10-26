# frozen_string_literal: true

require "rails_helper"

# Cooperative cancellation of background reviewer execution: the authorized
# action only records the request; the worker honors it at start or between
# cases, so collected evidence survives and no unevaluated case is fabricated.
# @spec INTENT-CONFORMANCE-ROLLOUT-011
RSpec.describe IntentConformance::ShadowEvaluation::CancelExecution do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account: account) }
  let(:project) { create(:project, account: account, created_by: owner) }
  let(:evaluation) { create(:intent_conformance_shadow_evaluation, :frozen, project: project, solo_maintainer: owner, created_by: owner) }

  it "refuses when no execution is queued or running" do
    result = described_class.call(evaluation: evaluation)

    expect(result).not_to be_success
    expect(result.error).to include("no reviewer execution")
  end

  it "requests cancellation of a queued execution without un-queueing it" do
    evaluation.update!(status: "queued", execution_queued_at: Time.current)

    result = described_class.call(evaluation: evaluation)

    expect(result).to be_success
    evaluation.reload
    expect(evaluation.cancel_requested_at).to be_present
    expect(evaluation).to be_queued
  end

  it "requests cancellation of a running execution; the worker stops between cases" do
    evaluation.update!(status: "running", execute_started_at: Time.current)

    result = described_class.call(evaluation: evaluation)

    expect(result).to be_success
    expect(evaluation.reload.cancel_requested_at).to be_present
    expect(evaluation).to be_running
  end

  it "refuses a second cancellation after the pass already ended cancelled" do
    evaluation.update!(status: "cancelled")

    expect(described_class.call(evaluation: evaluation)).not_to be_success
  end
end
