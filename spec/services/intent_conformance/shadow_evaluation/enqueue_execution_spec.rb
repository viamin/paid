# frozen_string_literal: true

require "rails_helper"

# Enqueue-side lifecycle of asynchronous reviewer execution (#4642): the
# originating request only authorizes and enqueues an idempotent operation —
# freeze-before-execution, pinned identity, digest, and deduplication
# semantics are validated before any reviewer spend, and duplicate
# submissions are refused while an execution is queued or running.
# @spec INTENT-CONFORMANCE-ROLLOUT-006
# @spec INTENT-CONFORMANCE-ROLLOUT-007
# @spec INTENT-CONFORMANCE-ROLLOUT-011
RSpec.describe IntentConformance::ShadowEvaluation::EnqueueExecution do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account: account) }
  let(:project) { create(:project, account: account, created_by: owner) }
  let(:dir) { Dir.mktmpdir }
  let(:cases) { [ corpus_case("A-01"), corpus_case("A-02", "stratum" => "intentionally_drifted") ] }
  let(:manifest_path) { write_corpus_manifest(dir, cases) }
  let(:evaluation) do
    create(:intent_conformance_shadow_evaluation, project: project, solo_maintainer: owner, created_by: owner,
      manifest_path: manifest_path, manifest_digest: Digest::SHA256.file(manifest_path).hexdigest)
  end

  after { FileUtils.remove_entry(dir) }

  def frozen_evaluation!
    label_all!(evaluation)
    freeze!(evaluation)
  end

  def raw_pg_session
    db_config = ActiveRecord::Base.connection_db_config.configuration_hash
    PG.connect(
      host: db_config[:host], port: db_config[:port], dbname: db_config[:database],
      user: db_config[:username], password: db_config[:password]
    )
  end

  it "refuses to enqueue before the reference set is frozen (blinding boundary)" do
    result = described_class.call(evaluation: evaluation)

    expect(result).not_to be_success
    expect(result.error).to include("frozen reference label set")
    expect(IntentConformance::ShadowEvaluation::ExecuteJob).not_to have_been_enqueued
    expect(evaluation.reload).to be_labeling
  end

  it "refuses to enqueue when the corpus manifest changed since freeze" do
    frozen_evaluation!
    File.write(manifest_path, { "cases" => cases + [ corpus_case("A-03") ], "reviewer" => reviewer_identity }.to_yaml)

    result = described_class.call(evaluation: evaluation)

    expect(result).not_to be_success
    expect(result.error).to include("manifest changed")
    expect(IntentConformance::ShadowEvaluation::ExecuteJob).not_to have_been_enqueued
  end

  it "refuses an unexecutable manifest reviewer identity before enqueueing" do
    stale_path = File.join(dir, "stale-manifest.yml")
    File.write(stale_path, { "cases" => cases, "reviewer" => {
      "model" => "claude-opus-4-6", "prompt_version" => "retired-prompt", "prompt_sha256" => "stale"
    } }.to_yaml)
    evaluation.update!(manifest_path: stale_path, manifest_digest: Digest::SHA256.file(stale_path).hexdigest)
    label_all!(evaluation)
    freeze!(evaluation)

    result = described_class.call(evaluation: evaluation)

    expect(result).not_to be_success
    expect(result.error).to include("prompt version")
    expect(IntentConformance::ShadowEvaluation::ExecuteJob).not_to have_been_enqueued
  end

  it "enqueues the idempotent background job and marks the evaluation queued" do
    frozen_evaluation!

    result = described_class.call(evaluation: evaluation)

    expect(result).to be_success
    expect(IntentConformance::ShadowEvaluation::ExecuteJob).to have_been_enqueued.with(evaluation.id).exactly(:once)
    expect(evaluation.reload).to be_queued
    expect(evaluation.execution_attempts).to eq(1)
    expect(evaluation.execute_heartbeat_at).to be_present
  end

  it "refuses duplicate submission while an execution is already queued" do
    frozen_evaluation!
    described_class.call(evaluation: evaluation)

    duplicate = described_class.call(evaluation: evaluation)

    expect(duplicate).not_to be_success
    expect(duplicate.error).to include("already queued")
    expect(IntentConformance::ShadowEvaluation::ExecuteJob).to have_been_enqueued.exactly(:once)
  end

  it "refuses submission while another invocation holds the execution lock" do
    frozen_evaluation!
    evaluation.update_columns(status: "executing", execute_heartbeat_at: Time.current)

    other_session = raw_pg_session
    begin
      other_session.exec_params(
        "SELECT pg_try_advisory_lock($1, $2)",
        [ IntentConformance::ShadowEvaluation::ExecuteReviewer::ADVISORY_LOCK_NAMESPACE, evaluation.id ]
      )

      result = described_class.call(evaluation: evaluation)

      expect(result).not_to be_success
      expect(result.error).to include("already in progress")
      expect(IntentConformance::ShadowEvaluation::ExecuteJob).not_to have_been_enqueued
    ensure
      other_session.close
    end
  end

  it "refuses to interrupt a fresh execution even when the lock probe is momentarily free" do
    frozen_evaluation!
    evaluation.update_columns(status: "executing", execute_heartbeat_at: 1.minute.ago)

    result = described_class.call(evaluation: evaluation)

    expect(result).not_to be_success
    expect(result.error).to include("already in progress")
    expect(IntentConformance::ShadowEvaluation::ExecuteJob).not_to have_been_enqueued
  end

  it "resumes a stale execution whose worker died and released the lock" do
    frozen_evaluation!
    described_class.call(evaluation: evaluation)
    evaluation.update_columns(status: "executing", execute_heartbeat_at: 2.hours.ago, execution_attempts: 1)

    result = described_class.call(evaluation: evaluation)

    expect(result).to be_success
    expect(result.resumed).to be(true)
    expect(evaluation.reload).to be_queued
    expect(evaluation.execution_attempts).to eq(2)
  end

  it "re-queues a queued evaluation whose enqueued job was lost" do
    frozen_evaluation!
    described_class.call(evaluation: evaluation)
    evaluation.update_column(:execute_heartbeat_at, 2.hours.ago)

    result = described_class.call(evaluation: evaluation)

    expect(result).to be_success
    expect(evaluation.reload).to be_queued
    expect(evaluation.execution_attempts).to eq(2)
  end

  it "allows an authorized retry from terminal execution states" do
    frozen_evaluation!
    %w[partial failed cancelled completed].each do |terminal|
      evaluation.update_columns(status: terminal, execution_attempts: 1)
      ActiveJob::Base.queue_adapter.enqueued_jobs.clear

      result = described_class.call(evaluation: evaluation.reload)

      expect(result).to be_success, "expected retry from #{terminal}: #{result.error}"
      expect(evaluation.reload).to be_queued
    end
  end

  it "clears a prior cancellation request when re-queuing a retry" do
    frozen_evaluation!
    evaluation.update_columns(status: "cancelled", cancel_requested_at: 1.hour.ago, execution_attempts: 1)

    result = described_class.call(evaluation: evaluation)

    expect(result).to be_success
    expect(evaluation.reload.cancel_requested_at).to be_nil
    expect(evaluation.reload.last_failure_reason).to be_nil
  end
end
