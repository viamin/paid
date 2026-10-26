# frozen_string_literal: true

require "rails_helper"

# @spec INTENT-CONFORMANCE-ROLLOUT-011
RSpec.describe IntentConformance::ShadowEvaluation::EnqueueExecution do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:, created_by: owner) }
  let(:evaluation) do
    create(:intent_conformance_shadow_evaluation, project:, created_by: owner, solo_maintainer: owner,
      status: "frozen", labels_frozen_at: Time.current)
  end

  it "queues an idempotent job rather than executing reviewer work in the request" do
    expect { described_class.call(evaluation:) }
      .to have_enqueued_job(IntentConformance::ShadowEvaluation::ExecuteJob).with(project.id, evaluation.id)

    expect(evaluation.reload).to be_queued
  end

  it "does not enqueue duplicate work while execution is already queued" do
    described_class.call(evaluation:)

    expect { described_class.call(evaluation:) }
      .not_to have_enqueued_job(IntentConformance::ShadowEvaluation::ExecuteJob)
  end
end
