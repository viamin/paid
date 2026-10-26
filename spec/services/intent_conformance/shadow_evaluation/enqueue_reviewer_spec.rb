# frozen_string_literal: true

require "rails_helper"

# @spec INTENT-CONFORMANCE-ROLLOUT-007 @spec INTENT-CONFORMANCE-ROLLOUT-009
RSpec.describe IntentConformance::ShadowEvaluation::EnqueueReviewer do
  include ActiveJob::TestHelper

  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:, created_by: owner) }
  let(:evaluation) { create(:intent_conformance_shadow_evaluation, :frozen, project:, solo_maintainer: owner, created_by: owner) }

  it "queues promptly and coalesces duplicate submissions" do
    allow(evaluation.corpus).to receive(:matches_recorded_digest?).and_return(true)

    expect {
      first = described_class.call(evaluation:)
      second = described_class.call(evaluation: evaluation.reload)

      expect(first).to be_success
      expect(first.enqueued).to be(true)
      expect(second).to be_success
      expect(second.enqueued).to be(false)
    }.to have_enqueued_job(ShadowEvaluationReviewerJob).once.with(evaluation.id)

    expect(evaluation.reload).to be_queued
  end
end
