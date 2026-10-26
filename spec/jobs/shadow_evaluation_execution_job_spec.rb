# frozen_string_literal: true

require "rails_helper"

# @spec INTENT-CONFORMANCE-ROLLOUT-011
RSpec.describe ShadowEvaluationExecutionJob do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:, created_by: owner) }
  let(:evaluation) do
    create(:intent_conformance_shadow_evaluation, project:, solo_maintainer: owner, created_by: owner,
      status: "queued", labels_frozen_at: Time.current, manifest_path: "docs/corpus.yml", manifest_digest: "digest")
  end

  it "does not execute a cancelled request" do
    evaluation.update!(status: "cancelled", cancellation_requested_at: Time.current)
    allow(IntentConformance::ShadowEvaluation::ExecuteReviewer).to receive(:call)

    described_class.perform_now(evaluation.id)

    expect(IntentConformance::ShadowEvaluation::ExecuteReviewer).not_to have_received(:call)
  end

  it "compiles the available report after a partial execution" do
    result = IntentConformance::ShadowEvaluation::ExecuteReviewer::Result.new(
      success: true, error: nil, evaluation:, executed: 1, failed: 1, cancelled: false
    )
    allow(IntentConformance::ShadowEvaluation::ExecuteReviewer).to receive(:call).and_return(result)
    allow(IntentConformance::ShadowEvaluation::CompileReport).to receive(:call)
    evaluation.runs.create!(case_id: "A-01", verdict: "within_scope", reviewer_run_id: "r1", reviewer_model: "m",
      prompt_digest: "d", cost_cents: 1, recorded_at: Time.current)

    described_class.perform_now(evaluation.id)

    expect(IntentConformance::ShadowEvaluation::CompileReport).to have_received(:call).with(evaluation: evaluation)
  end
end

# @spec INTENT-CONFORMANCE-ROLLOUT-011
RSpec.describe ShadowEvaluationExecutionRecoveryJob do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:, created_by: owner) }

  it "requeues a stale worker execution instead of leaving it running" do
    evaluation = create(:intent_conformance_shadow_evaluation, project:, solo_maintainer: owner, created_by: owner,
      status: "running", labels_frozen_at: Time.current, manifest_path: "docs/corpus.yml", manifest_digest: "digest")
    evaluation.update_columns(updated_at: 36.minutes.ago)

    expect {
      described_class.perform_now
    }.to have_enqueued_job(ShadowEvaluationExecutionJob).with(evaluation.id)

    expect(evaluation.reload).to be_queued
    expect(evaluation.last_failure_reason).to eq("recovered a stale worker execution")
  end
end
