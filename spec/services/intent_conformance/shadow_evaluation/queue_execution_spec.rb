# frozen_string_literal: true

require "rails_helper"

# @spec INTENT-CONFORMANCE-ROLLOUT-011
RSpec.describe IntentConformance::ShadowEvaluation::QueueExecution do
  include ActiveJob::TestHelper

  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:, created_by: owner) }
  let(:evaluation) { create(:intent_conformance_shadow_evaluation, :frozen, project:, solo_maintainer: owner, created_by: owner) }

  it "queues one idempotent execution and returns without running the reviewer" do
    expect {
      result = described_class.call(evaluation:)

      expect(result).to be_success
      expect(evaluation.reload).to be_queued
    }.to have_enqueued_job(IntentConformance::ShadowEvaluationExecutionJob).with(evaluation.id)

    expect { described_class.call(evaluation:) }.not_to have_enqueued_job(IntentConformance::ShadowEvaluationExecutionJob)
  end

  it "refuses execution before frozen labels and resumes partial work" do
    evaluation.update!(labels_frozen_at: nil, status: "labeling")
    expect(described_class.call(evaluation:)).not_to be_success

    evaluation.update!(labels_frozen_at: Time.current, status: "partial")
    expect(described_class.call(evaluation:)).to be_success
    expect(evaluation.reload).to be_queued
  end
end
