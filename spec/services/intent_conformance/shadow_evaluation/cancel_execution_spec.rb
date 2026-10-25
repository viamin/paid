# frozen_string_literal: true

require "rails_helper"

# Cancellation side of the asynchronous execution lifecycle (#4642): an
# authorized operator may stop a queued or running execution. Cancellation
# preserves every recorded run, never fabricates unevaluated results, and a
# queued execution cancels before any reviewer spend.
# @spec INTENT-CONFORMANCE-ROLLOUT-011
RSpec.describe IntentConformance::ShadowEvaluation::CancelExecution do
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

  it "refuses cancellation when nothing is queued or running" do
    result = described_class.call(evaluation: evaluation)

    expect(result).not_to be_success
    expect(result.error).to include("not queued or running")
  end

  it "cancels a queued execution before any reviewer spend" do
    evaluation.update_columns(status: "queued", execute_heartbeat_at: Time.current)

    result = described_class.call(evaluation: evaluation)

    expect(result).to be_success
    expect(result).to be_cancelled
    expect(evaluation.reload).to be_cancelled
    expect(evaluation.cancel_requested_at).to be_present
    expect(evaluation.runs).to be_empty
  end

  it "requests a running execution stop between cases" do
    evaluation.update_columns(status: "executing", execute_heartbeat_at: Time.current)

    result = described_class.call(evaluation: evaluation)

    expect(result).to be_success
    expect(result).to be_cancelling
    expect(evaluation.reload.cancel_requested_at).to be_present
    expect(evaluation).to be_executing
  end

  it "preserves recorded evidence instead of deleting or fabricating runs" do
    evaluation.update_columns(status: "executing", execute_heartbeat_at: Time.current)
    evaluation.runs.create!(case_id: "A-01", verdict: "within_scope", reviewer_run_id: "r1", reviewer_model: "m",
      prompt_digest: "d", cost_cents: 7, recorded_at: Time.current)

    result = described_class.call(evaluation: evaluation)

    expect(result).to be_success
    expect(evaluation.runs.count).to eq(1)
    expect(evaluation.runs.find_by(case_id: "A-01")).to be_evaluated
    expect(evaluation.runs.where.not(case_id: "A-01")).to be_empty
  end

  it "refuses cancellation of an already-terminal execution" do
    evaluation.update_columns(status: "completed")

    result = described_class.call(evaluation: evaluation)

    expect(result).not_to be_success
    expect(result.error).to include("not queued or running")
  end
end
