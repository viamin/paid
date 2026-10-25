# frozen_string_literal: true

require "rails_helper"

# Background execution of a frozen shadow evaluation (#4642): the queued job
# runs the real reviewer through agent_harness only for cases without an
# evaluated verdict, records verdicts/failures, and compiles the available
# report through the existing service. Successful verdict recording through
# the same ExecuteReviewer service is covered by its service spec; here the
# corpus deliberately references a repository outside the project so every
# reviewer attempt fails closed — prerequisite validation is never presented
# as execution. A cancellation before start means no reviewer spend; a
# terminal evaluation is left untouched.
# @spec INTENT-CONFORMANCE-ROLLOUT-007
# @spec INTENT-CONFORMANCE-ROLLOUT-011
RSpec.describe IntentConformance::ShadowEvaluation::ExecuteJob do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account: account) }
  let(:project) { create(:project, account: account, created_by: owner) }
  let(:dir) { Dir.mktmpdir }
  let(:cases) { [ corpus_case("A-01"), corpus_case("A-02") ] }
  let(:manifest_path) { write_corpus_manifest(dir, cases) }
  let(:evaluation) do
    create(:intent_conformance_shadow_evaluation, project: project, solo_maintainer: owner, created_by: owner,
      manifest_path: manifest_path, manifest_digest: Digest::SHA256.file(manifest_path).hexdigest)
  end

  before { allow(AgentHarness).to receive(:send_message) }

  after { FileUtils.remove_entry(dir) }

  def queue_evaluation!
    IntentConformance::ShadowEvaluation::EnqueueExecution.call(evaluation: evaluation)
  end

  it "executes the queued evaluation, records closed failures, and compiles the report" do
    label_all!(evaluation)
    freeze!(evaluation)
    queue_evaluation!

    described_class.perform_now(evaluation.id)

    expect(AgentHarness).not_to have_received(:send_message)
    expect(evaluation.reload).to be_failed
    expect(evaluation.runs.count).to eq(2)
    expect(evaluation.runs).to all(be_not_evaluated)
    expect(evaluation.report).to be_present
    expect(evaluation.report_markdown).to include("Solo-Maintainer Shadow Evaluation Report")
    expect(evaluation.execute_heartbeat_at).to be_present
  end

  it "performs no reviewer spend when cancellation landed before the job started" do
    label_all!(evaluation)
    freeze!(evaluation)
    queue_evaluation!
    IntentConformance::ShadowEvaluation::CancelExecution.call(evaluation: evaluation.reload)

    described_class.perform_now(evaluation.id)

    expect(AgentHarness).not_to have_received(:send_message)
    expect(evaluation.reload).to be_cancelled
    expect(evaluation.runs).to be_empty
  end

  it "leaves a terminal evaluation untouched" do
    label_all!(evaluation)
    freeze!(evaluation)
    evaluation.update_columns(status: "completed", execution_attempts: 1)

    expect { described_class.perform_now(evaluation.id) }.not_to change { evaluation.reload.updated_at }
    expect(AgentHarness).not_to have_received(:send_message)
  end

  it "marks a partial retry partial without repeating completed-case spend" do
    label_all!(evaluation)
    freeze!(evaluation)
    evaluation.runs.create!(case_id: "A-01", verdict: "within_scope", reviewer_run_id: "r1", reviewer_model: "m",
      prompt_digest: "d", cost_cents: 42, recorded_at: Time.current)
    queue_evaluation!

    described_class.perform_now(evaluation.id)

    # A-01 keeps its earlier verdict (no new spend); A-02 fails closed.
    expect(AgentHarness).not_to have_received(:send_message)
    expect(evaluation.reload).to be_partial
    expect(evaluation.runs.find_by(case_id: "A-01")).to be_evaluated
    expect(evaluation.runs.find_by(case_id: "A-02")).to be_not_evaluated
    expect(evaluation.report).to be_present
    expect(evaluation.report.fetch("measures").fetch("not_evaluated_cases")).to eq(1)
  end

  it "fails the evaluation with the validation error when state changed between enqueue and perform" do
    label_all!(evaluation)
    freeze!(evaluation)
    queue_evaluation!
    File.write(manifest_path, { "cases" => cases + [ corpus_case("A-03") ], "reviewer" => reviewer_identity }.to_yaml)

    described_class.perform_now(evaluation.id)

    expect(AgentHarness).not_to have_received(:send_message)
    expect(evaluation.reload).to be_failed
    expect(evaluation.last_failure_reason).to include("manifest changed")
  end
end
