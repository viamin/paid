# frozen_string_literal: true

require "rails_helper"

# Enqueue-only admission to background reviewer execution: the triggering
# request authorizes and claims the evaluation as queued, but no reviewer
# call happens inline. Duplicate submissions reuse the in-flight lifecycle.
# @spec INTENT-CONFORMANCE-ROLLOUT-006
# @spec INTENT-CONFORMANCE-ROLLOUT-011
RSpec.describe IntentConformance::ShadowEvaluation::EnqueueExecution do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account: account) }
  let(:project) { create(:project, account: account, created_by: owner) }
  let(:dir) { Dir.mktmpdir }
  let(:cases) { [ corpus_case("A-01"), corpus_case("A-02") ] }
  let(:manifest_path) { write_corpus_manifest(dir, cases) }
  let(:evaluation) do
    create(:intent_conformance_shadow_evaluation, :frozen, project: project, solo_maintainer: owner, created_by: owner,
      manifest_path: manifest_path, manifest_digest: Digest::SHA256.file(manifest_path).hexdigest)
  end

  after { FileUtils.remove_entry(dir) }

  it "refuses to enqueue before the reference set is frozen (blinding boundary)" do
    labeling = create(:intent_conformance_shadow_evaluation, project: project, solo_maintainer: owner, created_by: owner,
      manifest_path: manifest_path, manifest_digest: Digest::SHA256.file(manifest_path).hexdigest)

    result = described_class.call(evaluation: labeling, actor: owner)

    expect(result).not_to be_success
    expect(result.error).to include("frozen reference label set")
    expect { described_class.call(evaluation: labeling, actor: owner) }.not_to have_enqueued_job(ShadowEvaluationExecuteJob)
  end

  it "claims the evaluation as queued and enqueues exactly one background execution" do
    expect { described_class.call(evaluation: evaluation, actor: owner) }
      .to have_enqueued_job(ShadowEvaluationExecuteJob).with(evaluation.id).exactly(:once)

    evaluation.reload
    expect(evaluation).to be_queued
    expect(evaluation.execution_queued_at).to be_present
    expect(evaluation.runs).to be_empty
  end

  it "treats a duplicate submission while queued or running as idempotent" do
    described_class.call(evaluation: evaluation, actor: owner)

    second = described_class.call(evaluation: evaluation, actor: owner)

    expect(second).to be_success
    expect(second).to be_already_active
    expect { second }.not_to have_enqueued_job(ShadowEvaluationExecuteJob)
    expect(evaluation.reload).to be_queued
  end

  it "refuses while another invocation is already running" do
    evaluation.update!(status: "running", execute_started_at: Time.current, execution_heartbeat_at: Time.current)

    result = described_class.call(evaluation: evaluation, actor: owner)

    expect(result).to be_success
    expect(result).to be_already_active
    expect { result }.not_to have_enqueued_job(ShadowEvaluationExecuteJob)
  end

  it "re-queues from a cancelled or partial pass and clears the stale cancellation" do
    evaluation.update!(status: "cancelled", cancel_requested_at: 1.minute.ago, last_failure_reason: "cancelled by operator")

    expect { described_class.call(evaluation: evaluation, actor: owner) }
      .to have_enqueued_job(ShadowEvaluationExecuteJob).exactly(:once)

    evaluation.reload
    expect(evaluation).to be_queued
    expect(evaluation.cancel_requested_at).to be_nil
    expect(evaluation.last_failure_reason).to be_nil
  end

  it "fails closed when the corpus manifest changed since the labels were frozen" do
    evaluation.update!(manifest_digest: "stale")

    result = described_class.call(evaluation: evaluation, actor: owner)

    expect(result).not_to be_success
    expect(result.error).to include("manifest changed")
    expect { result }.not_to have_enqueued_job(ShadowEvaluationExecuteJob)
  end

  it "refuses an unexecutable manifest reviewer identity before enqueueing" do
    evaluation # create the evaluation against the original manifest first
    unexecutable = write_corpus_manifest(dir, cases, "reviewer" => {
      "model" => "claude-sonnet-4-6",
      "prompt_version" => "retired-reviewer-prompt",
      "prompt_sha256" => "stale-prompt-digest"
    })
    evaluation.update!(manifest_path: unexecutable, manifest_digest: Digest::SHA256.file(unexecutable).hexdigest)

    result = described_class.call(evaluation: evaluation, actor: owner)

    expect(result).not_to be_success
    expect(result.error).to include("prompt version")
    expect { result }.not_to have_enqueued_job(ShadowEvaluationExecuteJob)
  end
end
