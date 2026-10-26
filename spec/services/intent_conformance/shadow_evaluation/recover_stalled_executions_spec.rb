# frozen_string_literal: true

require "rails_helper"

# Bounded asynchronous recovery: a lost queued job is re-enqueued and a dead
# worker (stale heartbeat) is resumed or folded to cancelled, so no
# evaluation strands indefinitely as queued/executing. Re-enqueueing is safe:
# the advisory lock keeps a live worker the sole lifecycle owner, and executed
# cases are never re-spent.
# @spec INTENT-CONFORMANCE-ROLLOUT-011
RSpec.describe IntentConformance::ShadowEvaluation::RecoverStalledExecutions do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account: account) }
  let(:project) { create(:project, account: account, created_by: owner) }
  let(:evaluation) { create(:intent_conformance_shadow_evaluation, :frozen, project: project, solo_maintainer: owner, created_by: owner) }
  let(:stale_cutoff) { described_class::STALE_AFTER + 1.minute }

  def stale_times
    { execution_queued_at: stale_cutoff.ago, execution_heartbeat_at: stale_cutoff.ago,
      execute_started_at: stale_cutoff.ago, updated_at: stale_cutoff.ago }
  end

  it "re-enqueues a queued execution whose job was lost" do
    evaluation.update!(status: "queued", **stale_times)

    result = described_class.call

    expect(result.requeued).to eq(1)
    expect { described_class.call }.not_to change { evaluation.reload.status }
    expect(ShadowEvaluationExecuteJob).to have_been_enqueued.with(evaluation.id).at_least(:once)
  end

  it "leaves a freshly queued execution alone" do
    evaluation.update!(status: "queued", execution_queued_at: 1.minute.ago)

    result = described_class.call

    expect(result.requeued).to eq(0)
    expect(ShadowEvaluationExecuteJob).not_to have_been_enqueued
  end

  it "re-enqueues a running execution whose worker heartbeat went stale" do
    evaluation.update!(status: "running", **stale_times)

    result = described_class.call

    expect(result.requeued).to eq(1)
    expect(evaluation.reload).to be_running
    expect(ShadowEvaluationExecuteJob).to have_been_enqueued.with(evaluation.id)
  end

  it "resumes a legacy executing row stranded by the pre-async code" do
    evaluation.update!(status: "executing", **stale_times)

    result = described_class.call

    expect(result.requeued).to eq(1)
    expect(ShadowEvaluationExecuteJob).to have_been_enqueued.with(evaluation.id)
  end

  it "leaves a freshly heart-beating running execution alone" do
    evaluation.update!(status: "running", execution_heartbeat_at: 1.minute.ago, execute_started_at: 1.minute.ago)

    result = described_class.call

    expect(result.requeued).to eq(0)
    expect(ShadowEvaluationExecuteJob).not_to have_been_enqueued
  end

  it "leaves terminal and labeling evaluations alone" do
    evaluation.update!(status: "completed", **stale_times)
    create(:intent_conformance_shadow_evaluation, project: project, solo_maintainer: owner, created_by: owner)
      .update!(status: "labeling", **stale_times)

    result = described_class.call

    expect(result.requeued).to eq(0)
    expect(ShadowEvaluationExecuteJob).not_to have_been_enqueued
  end
end
