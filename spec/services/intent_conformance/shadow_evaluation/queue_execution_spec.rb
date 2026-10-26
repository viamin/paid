# frozen_string_literal: true

require "rails_helper"

# @spec INTENT-CONFORMANCE-ROLLOUT-011
RSpec.describe IntentConformance::ShadowEvaluation::QueueExecution do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:, created_by: owner) }
  let(:dir) { Dir.mktmpdir }
  let(:manifest_path) { write_corpus_manifest(dir, [ corpus_case("A-01") ]) }
  let(:evaluation) do
    create(:intent_conformance_shadow_evaluation, project:, solo_maintainer: owner, created_by: owner,
      manifest_path:, manifest_digest: Digest::SHA256.file(manifest_path).hexdigest)
  end
  let(:job_class) { class_double(IntentConformance::ShadowEvaluationJob, perform_later: true) }

  after { FileUtils.remove_entry(dir) }

  it "queues an idempotent operation without reviewer I/O" do
    label_all!(evaluation)
    freeze!(evaluation)

    result = described_class.call(evaluation:, job_class:)

    expect(result).to be_success
    expect(result.enqueued).to be(true)
    expect(evaluation.reload).to be_queued
    expect(evaluation.execution_requested_at).to be_present
    expect(job_class).to have_received(:perform_later).with(evaluation.id)

    duplicate = described_class.call(evaluation:, job_class:)
    expect(duplicate).to be_success
    expect(duplicate.enqueued).to be(false)
    expect(job_class).to have_received(:perform_later).once
  end

  it "requeues stale work so a lost worker cannot strand an evaluation" do
    label_all!(evaluation)
    freeze!(evaluation)
    evaluation.update!(status: "running", execution_heartbeat_at: 16.minutes.ago)

    result = described_class.call(evaluation:, job_class:)

    expect(result).to be_success
    expect(result.enqueued).to be(true)
    expect(evaluation.reload).to be_queued
  end
end
