# frozen_string_literal: true

require "rails_helper"

# The cron-driven recovery job (#4642): bounded, single-instance sweep that
# delegates to the recovery service under system access (evaluations span
# tenants) and logs only when it acted.
# @spec INTENT-CONFORMANCE-ROLLOUT-011
RSpec.describe IntentConformance::ShadowEvaluations::RecoveryJob do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account: account) }
  let(:project) { create(:project, account: account, created_by: owner) }
  let(:dir) { Dir.mktmpdir }
  let(:manifest_path) { write_corpus_manifest(dir, [ corpus_case("A-01"), corpus_case("A-02") ]) }
  let(:evaluation) do
    create(:intent_conformance_shadow_evaluation, :frozen, project: project, solo_maintainer: owner, created_by: owner,
      manifest_path: manifest_path, manifest_digest: Digest::SHA256.file(manifest_path).hexdigest)
  end

  after { FileUtils.remove_entry(dir) }

  it "returns a stale running execution to a retryable state with evidence preserved" do
    evaluation.update!(status: "running", execute_started_at: 2.hours.ago, execute_heartbeat_at: 2.hours.ago)
    evaluation.runs.create!(case_id: "A-01", verdict: "within_scope", reviewer_run_id: "r1",
      reviewer_model: "m", prompt_digest: "d", cost_cents: 42, recorded_at: Time.current)

    described_class.perform_now

    evaluation.reload
    expect(evaluation).to be_partial
    expect(evaluation.report_markdown).to be_present
    expect(evaluation.runs.count).to eq(1)
  end

  it "re-enqueues a stale queued execution whose job row was lost" do
    evaluation.update!(status: "queued", execute_queued_at: 2.hours.ago)

    expect { described_class.perform_now }
      .to have_enqueued_job(IntentConformance::ShadowEvaluations::ExecuteJob).with(evaluation.id)
  end

  it "does nothing when nothing is stale" do
    evaluation.update!(status: "running", execute_started_at: 1.minute.ago, execute_heartbeat_at: 1.minute.ago)

    expect { described_class.perform_now }
      .not_to have_enqueued_job(IntentConformance::ShadowEvaluations::ExecuteJob)
    expect(evaluation.reload).to be_running
  end
end
