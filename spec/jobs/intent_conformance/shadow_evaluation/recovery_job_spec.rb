# frozen_string_literal: true

require "rails_helper"

# Bounded asynchronous recovery for shadow-evaluation executions (#4642): a
# killed worker, expired request, or lost execution lock must not strand an
# evaluation indefinitely as executing. The sweep probes per-case heartbeats
# and the advisory execution lock, resumes bounded attempts, and fails
# executions that keep getting interrupted.
# @spec INTENT-CONFORMANCE-ROLLOUT-011
RSpec.describe IntentConformance::ShadowEvaluation::RecoveryJob do
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

  def raw_pg_session
    db_config = ActiveRecord::Base.connection_db_config.configuration_hash
    PG.connect(
      host: db_config[:host], port: db_config[:port], dbname: db_config[:database],
      user: db_config[:username], password: db_config[:password]
    )
  end

  it "leaves a fresh executing evaluation alone" do
    evaluation.update_columns(status: "executing", execute_heartbeat_at: 1.minute.ago)

    described_class.perform_now

    expect(IntentConformance::ShadowEvaluation::ExecuteJob).not_to have_been_enqueued
    expect(evaluation.reload).to be_executing
  end

  it "leaves a stale-heartbeat evaluation alone while another session still holds the execution lock" do
    evaluation.update_columns(status: "executing", execute_heartbeat_at: 2.hours.ago)

    other_session = raw_pg_session
    begin
      other_session.exec_params(
        "SELECT pg_try_advisory_lock($1, $2)",
        [ IntentConformance::ShadowEvaluation::ExecuteReviewer::ADVISORY_LOCK_NAMESPACE, evaluation.id ]
      )

      described_class.perform_now

      expect(IntentConformance::ShadowEvaluation::ExecuteJob).not_to have_been_enqueued
      expect(evaluation.reload).to be_executing
    ensure
      other_session.close
    end
  end

  it "resumes an execution stranded by a killed worker within the bounded attempts" do
    evaluation.update_columns(status: "executing", execute_heartbeat_at: 2.hours.ago, execution_attempts: 1)

    described_class.perform_now

    expect(IntentConformance::ShadowEvaluation::ExecuteJob).to have_been_enqueued.with(evaluation.id).exactly(:once)
    expect(evaluation.reload).to be_queued
    expect(evaluation.execution_attempts).to eq(2)
  end

  it "re-queues a queued evaluation whose enqueued job was lost" do
    evaluation.update_columns(status: "queued", execute_heartbeat_at: 2.hours.ago, execution_attempts: 1)

    described_class.perform_now

    expect(IntentConformance::ShadowEvaluation::ExecuteJob).to have_been_enqueued.with(evaluation.id).exactly(:once)
    expect(evaluation.reload).to be_queued
  end

  it "fails an execution that exhausted the bounded recovery attempts" do
    evaluation.update_columns(status: "executing", execute_heartbeat_at: 2.hours.ago,
      execution_attempts: IntentConformance::ShadowEvaluation::RecoveryJob::MAX_RECOVERY_RESUMES)

    described_class.perform_now

    expect(IntentConformance::ShadowEvaluation::ExecuteJob).not_to have_been_enqueued
    expect(evaluation.reload).to be_failed
    expect(evaluation.last_failure_reason).to include("interrupted")
  end

  it "finishes a pending cancellation instead of resurrecting interrupted spend" do
    evaluation.update_columns(status: "executing", execute_heartbeat_at: 2.hours.ago, cancel_requested_at: 1.hour.ago)
    evaluation.runs.create!(case_id: "A-01", verdict: "within_scope", reviewer_run_id: "r1", reviewer_model: "m",
      prompt_digest: "d", cost_cents: 42, recorded_at: Time.current)

    described_class.perform_now

    expect(IntentConformance::ShadowEvaluation::ExecuteJob).not_to have_been_enqueued
    expect(evaluation.reload).to be_cancelled
    expect(evaluation.runs.find_by(case_id: "A-01")).to be_evaluated
  end

  it "ignores terminal evaluations" do
    evaluation.update_columns(status: "completed")

    described_class.perform_now

    expect(IntentConformance::ShadowEvaluation::ExecuteJob).not_to have_been_enqueued
    expect(evaluation.reload).to be_completed
  end
end
