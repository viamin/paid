# frozen_string_literal: true

require "rails_helper"

# @spec INTENT-CONFORMANCE-ROLLOUT-010
RSpec.describe IntentConformanceShadowEvaluationRecoveryJob do
  include ActiveJob::TestHelper
  include ShadowEvaluationCorpusHelper

  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account: account) }
  let(:project) { create(:project, account: account, created_by: owner) }
  let(:directory) { Dir.mktmpdir }
  let(:manifest_path) { write_corpus_manifest(directory, [ corpus_case("A-01") ]) }
  let(:evaluation) do
    create(:intent_conformance_shadow_evaluation, project: project, solo_maintainer: owner, created_by: owner,
      manifest_path: manifest_path, manifest_digest: Digest::SHA256.file(manifest_path).hexdigest)
  end

  before do
    label_all!(evaluation)
    freeze!(evaluation)
    evaluation.update!(status: "running", execution_heartbeat_at: 10.minutes.ago)
  end

  after { FileUtils.remove_entry(directory) }

  it "requeues a stale worker without changing collected evidence" do
    evaluation.runs.create!(case_id: "A-01", verdict: "within_scope", reviewer_run_id: "run-1", reviewer_model: "model",
      prompt_digest: "digest", cost_cents: 7, recorded_at: Time.current)

    expect {
      described_class.perform_now
    }.to have_enqueued_job(IntentConformanceShadowEvaluationExecutionJob).with(evaluation.id, 1)

    expect(evaluation.reload).to be_queued
    expect(evaluation.runs.find_by(case_id: "A-01")).to be_evaluated
  end
end
