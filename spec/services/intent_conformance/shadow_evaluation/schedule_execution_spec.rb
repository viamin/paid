# frozen_string_literal: true

require "rails_helper"

# @spec INTENT-CONFORMANCE-ROLLOUT-010
RSpec.describe IntentConformance::ShadowEvaluation::ScheduleExecution do
  include ActiveJob::TestHelper

  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account: account) }
  let(:project) { create(:project, account: account, created_by: owner) }
  let(:directory) { Dir.mktmpdir }
  let(:manifest_path) { write_corpus_manifest(directory, [ corpus_case("A-01") ]) }
  let(:evaluation) do
    create(:intent_conformance_shadow_evaluation, project: project, solo_maintainer: owner, created_by: owner,
      manifest_path: manifest_path, manifest_digest: Digest::SHA256.file(manifest_path).hexdigest)
  end

  before { label_all!(evaluation); freeze!(evaluation) }
  after { FileUtils.remove_entry(directory) }

  it "queues one durable operation and leaves reviewer work to the worker" do
    expect {
      result = described_class.call(evaluation: evaluation)
      expect(result).to be_success
      expect(result.enqueued?).to be(true)
    }.to have_enqueued_job(IntentConformanceShadowEvaluationExecutionJob).with(evaluation.id, 1)

    expect(evaluation.reload).to be_queued
    expect(evaluation.execution_heartbeat_at).to be_present
  end

  it "deduplicates a fresh queued operation" do
    described_class.call(evaluation: evaluation)

    expect {
      result = described_class.call(evaluation: evaluation)
      expect(result).to be_success
      expect(result.enqueued?).to be(false)
    }.not_to have_enqueued_job(IntentConformanceShadowEvaluationExecutionJob)
  end

  it "recovers a stale running worker by queueing a replacement" do
    evaluation.update!(status: "running", execution_heartbeat_at: 10.minutes.ago)

    expect {
      result = described_class.call(evaluation: evaluation)
      expect(result).to be_success
      expect(result.enqueued?).to be(true)
    }.to have_enqueued_job(IntentConformanceShadowEvaluationExecutionJob).with(evaluation.id, 1)

    expect(evaluation.reload).to be_queued
  end

  it "recovers a stale queued worker by queueing a replacement" do
    evaluation.update!(status: "queued", execution_heartbeat_at: 10.minutes.ago)

    expect {
      result = described_class.call(evaluation: evaluation)
      expect(result).to be_success
      expect(result.enqueued?).to be(true)
    }.to have_enqueued_job(IntentConformanceShadowEvaluationExecutionJob).with(evaluation.id, 1)
  end
end
