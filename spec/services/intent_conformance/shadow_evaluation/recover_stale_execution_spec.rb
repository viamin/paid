# frozen_string_literal: true

require "rails_helper"

# Bounded recovery for the async execution lifecycle (#4642): a killed
# worker, expired request, or lost lock must never strand an evaluation
# indefinitely as queued/running, and recovery never fabricates evidence.
# @spec INTENT-CONFORMANCE-ROLLOUT-011
RSpec.describe IntentConformance::ShadowEvaluation::RecoverStaleExecution do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account: account) }
  let(:project) { create(:project, account: account, created_by: owner) }
  let(:dir) { Dir.mktmpdir }
  let(:manifest_path) { write_corpus_manifest(dir, [ corpus_case("A-01"), corpus_case("A-02") ]) }
  let(:evaluation) do
    create(:intent_conformance_shadow_evaluation, :frozen, project: project, solo_maintainer: owner, created_by: owner,
      manifest_path: manifest_path, manifest_digest: Digest::SHA256.file(manifest_path).hexdigest)
  end
  let(:stale) { described_class::STALE_AFTER + 1.minute }
  let(:fresh) { 1.minute.ago }

  after { FileUtils.remove_entry(dir) }

  def running_since(heartbeat_at, started_at = heartbeat_at)
    evaluation.update!(status: "running", execute_started_at: started_at, execute_heartbeat_at: heartbeat_at)
  end

  it "returns a stale running execution with collected verdicts to partial and attaches the available report" do
    evaluation.runs.create!(case_id: "A-01", verdict: "within_scope", reviewer_run_id: "r1",
      reviewer_model: "claude-sonnet-4-6", prompt_digest: "d", cost_cents: 42, recorded_at: Time.current)
    running_since(stale.ago)

    result = described_class.call

    expect(result.recovered).to eq(1)
    evaluation.reload
    expect(evaluation).to be_partial
    expect(evaluation.last_failure_reason).to include("interrupted")
    expect(evaluation.report_markdown).to be_present
    expect(evaluation.runs.count).to eq(1)
  end

  it "returns a stale running execution without any evaluated verdict to failed" do
    running_since(stale.ago)

    result = described_class.call

    expect(result.recovered).to eq(1)
    expect(evaluation.reload).to be_failed
    expect(evaluation.last_failure_reason).to include("interrupted")
    expect(evaluation.runs).to be_empty
  end

  it "recovers a legacy `executing` record from before the async lifecycle" do
    evaluation.update_column(:status, "executing")
    evaluation.update_columns(execute_started_at: stale.ago, execute_heartbeat_at: stale.ago)

    result = described_class.call

    expect(result.recovered).to eq(1)
    expect(evaluation.reload).to be_failed
  end

  it "leaves a live running execution (fresh heartbeat) untouched" do
    running_since(fresh)

    result = described_class.call

    expect(result.recovered).to eq(0)
    expect(evaluation.reload).to be_running
  end

  it "re-enqueues a stale queued execution whose job row was lost, at a bounded cadence" do
    evaluation.update!(status: "queued", execute_queued_at: stale.ago)

    result = described_class.call

    expect(result.requeued).to eq(1)
    expect(IntentConformance::ShadowEvaluations::ExecuteJob).to have_been_enqueued.with(evaluation.id)
    expect(evaluation.reload).to be_queued
    expect(evaluation.reload.execute_queued_at).to be_within(2.seconds).of(Time.current)
  end

  it "leaves a recently queued execution alone" do
    evaluation.update!(status: "queued", execute_queued_at: fresh)

    result = described_class.call

    expect(result.requeued).to eq(0)
    expect(IntentConformance::ShadowEvaluations::ExecuteJob).not_to have_been_enqueued
  end
end
