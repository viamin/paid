# frozen_string_literal: true

require "rails_helper"

# @spec INTENT-CONFORMANCE-ROLLOUT-011
RSpec.describe IntentConformance::ShadowEvaluation::EnqueueExecution do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:, created_by: owner) }
  let(:evaluation) { create(:intent_conformance_shadow_evaluation, :frozen, project:, solo_maintainer: owner, created_by: owner) }

  before do
    allow(evaluation).to receive(:corpus).and_return(instance_double(IntentConformance::ShadowEvaluationCorpus,
      matches_recorded_digest?: true, case_ids: [ "A-01" ], reviewer_identity: reviewer_identity))
  end

  it "durably queues exactly one execution for repeated submissions" do
    expect {
      first = described_class.call(evaluation:)
      expect(first).to be_success
      expect(first.enqueued).to be(true)
    }.to have_enqueued_job(IntentConformance::ShadowEvaluation::ExecuteJob).with(evaluation.id)

    second = described_class.call(evaluation:)

    expect(second).to be_success
    expect(second.enqueued).to be(false)
    expect(evaluation.reload).to be_queued
  end

  it "reclaims an expired worker lease for a safe resume" do
    evaluation.update!(status: "running", execution_lease_expires_at: 1.minute.ago)
    evaluation.runs.create!(case_id: "A-01", verdict: "within_scope", reviewer_run_id: "completed",
      reviewer_model: "model", prompt_digest: "digest", cost_cents: 42, recorded_at: Time.current)

    result = described_class.call(evaluation:)

    expect(result).to be_success
    expect(result.enqueued).to be(true)
    expect(evaluation.reload).to be_queued
    expect(evaluation.runs.find_by!(case_id: "A-01")).to have_attributes(verdict: "within_scope", cost_cents: 42)
  end
end
