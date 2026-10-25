# frozen_string_literal: true

require "rails_helper"

# Authorized cancellation of the async execution lifecycle (#4642): the
# request only records the intent; the job honors it before starting and the
# executor honors it between cases, preserving collected evidence without
# fabricating unevaluated results.
# @spec INTENT-CONFORMANCE-ROLLOUT-011
RSpec.describe IntentConformance::ShadowEvaluation::CancelExecution do
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

  it "refuses when no execution is queued or running" do
    result = described_class.call(evaluation: evaluation)

    expect(result).not_to be_success
    expect(result.error).to include("not queued or running")
    expect(evaluation.reload.cancel_requested_at).to be_nil
  end

  it "records the cancellation request for a queued execution without touching collected evidence" do
    evaluation.update!(status: "queued", execute_queued_at: Time.current)

    result = described_class.call(evaluation: evaluation)

    expect(result).to be_success
    expect(evaluation.reload.cancel_requested_at).to be_present
    expect(evaluation.reload).to be_queued
  end

  it "records the cancellation request for a running execution" do
    evaluation.update!(status: "running", execute_started_at: Time.current)

    result = described_class.call(evaluation: evaluation)

    expect(result).to be_success
    expect(evaluation.reload.cancel_requested_at).to be_present
  end

  describe ".finalize" do
    it "marks the execution cancelled with evidence preserved and the available report attached" do
      evaluation.runs.create!(case_id: "A-01", verdict: "within_scope", reviewer_run_id: "r1",
        reviewer_model: "claude-sonnet-4-6", prompt_digest: "d", cost_cents: 42, recorded_at: Time.current)

      described_class.finalize(evaluation.reload, reason: "cancelled by operator")

      evaluation.reload
      expect(evaluation).to be_cancelled
      expect(evaluation.cancelled_at).to be_present
      expect(evaluation.last_failure_reason).to include("cancelled by operator")
      expect(evaluation.runs.count).to eq(1)
      expect(evaluation.report_markdown).to be_present
    end

    it "never fabricates unevaluated results for untouched cases" do
      described_class.finalize(evaluation, reason: "cancelled by operator")

      expect(evaluation.reload.runs).to be_empty
      expect(evaluation.report).to be_empty
    end
  end
end
