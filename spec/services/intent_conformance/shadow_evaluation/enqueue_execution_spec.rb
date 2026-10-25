# frozen_string_literal: true

require "rails_helper"

# The authorize-and-enqueue half of the async execution lifecycle (#4642):
# the request never runs the corpus; it claims the queued state atomically
# (duplicate submissions cannot double-enqueue), preserves the
# freeze-before-execution gate, and hands off to the idempotent job.
# @spec INTENT-CONFORMANCE-ROLLOUT-011
RSpec.describe IntentConformance::ShadowEvaluation::EnqueueExecution do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account: account) }
  let(:project) { create(:project, account: account, created_by: owner) }
  let(:dir) { Dir.mktmpdir }
  let(:manifest_path) { write_corpus_manifest(dir, [ corpus_case("A-01") ]) }
  let(:evaluation) do
    create(:intent_conformance_shadow_evaluation, project: project, solo_maintainer: owner, created_by: owner,
      manifest_path: manifest_path, manifest_digest: Digest::SHA256.file(manifest_path).hexdigest)
  end

  after { FileUtils.remove_entry(dir) }

  it "refuses to enqueue before the reference set is frozen (blinding boundary)" do
    allow(IntentConformance::ShadowEvaluations::ExecuteJob).to receive(:perform_later)
    result = described_class.call(evaluation: evaluation)

    expect(result).not_to be_success
    expect(result.error).to include("frozen reference label set")
    expect(IntentConformance::ShadowEvaluations::ExecuteJob).not_to have_received(:perform_later)
    expect(evaluation.reload).not_to be_queued
  end

  it "claims queued and enqueues the idempotent job" do
    label_all!(evaluation)
    freeze!(evaluation)

    result = described_class.call(evaluation: evaluation)

    expect(result).to be_success
    expect(IntentConformance::ShadowEvaluations::ExecuteJob).to have_been_enqueued.with(evaluation.id)
    evaluation.reload
    expect(evaluation).to be_queued
    expect(evaluation.execute_queued_at).to be_present
  end

  it "refuses duplicate submission while an execution is queued or running" do
    label_all!(evaluation)
    freeze!(evaluation)
    evaluation.update!(status: "queued", execute_queued_at: Time.current)
    allow(IntentConformance::ShadowEvaluations::ExecuteJob).to receive(:perform_later)

    result = described_class.call(evaluation: evaluation)

    expect(result).not_to be_success
    expect(result.error).to include("already queued or running")
    expect(IntentConformance::ShadowEvaluations::ExecuteJob).not_to have_received(:perform_later)
  end

  it "clears a stale cancellation request when re-queuing a retry" do
    label_all!(evaluation)
    freeze!(evaluation)
    evaluation.update!(status: "cancelled", cancel_requested_at: 1.hour.ago, cancelled_at: 1.hour.ago)

    result = described_class.call(evaluation: evaluation)

    expect(result).to be_success
    evaluation.reload
    expect(evaluation).to be_queued
    expect(evaluation.cancel_requested_at).to be_nil
    expect(evaluation.cancelled_at).to be_present
  end

  it "loses the claim race atomically when a concurrent request already queued the execution" do
    label_all!(evaluation)
    freeze!(evaluation)
    # A second request's claim lands after ours flipped the status.
    evaluation.update_column(:status, "running")
    allow(IntentConformance::ShadowEvaluations::ExecuteJob).to receive(:perform_later)

    result = described_class.call(evaluation: evaluation)

    expect(result).not_to be_success
    expect(IntentConformance::ShadowEvaluations::ExecuteJob).not_to have_received(:perform_later)
    expect(evaluation.reload).to be_running
  end
end
