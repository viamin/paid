# frozen_string_literal: true

require "rails_helper"

# @spec INTENT-CONFORMANCE-ROLLOUT-008
RSpec.describe IntentConformance::ShadowEvaluation::CompileReport do
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

  def freeze_with_labels!
    IntentConformance::ShadowEvaluation::RecordLabel.call(evaluation: evaluation, actor: owner, case_id: "A-01",
      outcome: "within_scope", cited_design_claim: "claim", reason: "reason")
    IntentConformance::ShadowEvaluation::RecordLabel.call(evaluation: evaluation, actor: owner, case_id: "A-02",
      outcome: "material_drift", cited_design_claim: "claim", reason: "reason")
    freeze!(evaluation)
  end

  def record_run(case_id:, verdict:, failure_reason: nil, cost_cents: 25)
    evaluation.runs.create!(case_id: case_id, verdict: verdict, failure_reason: failure_reason,
      reviewer_run_id: "run-#{case_id}", reviewer_model: "claude-sonnet-4-6", prompt_digest: "digest", cost_cents: cost_cents, recorded_at: Time.current)
  end

  it "refuses to compile before reviewer runs exist" do
    freeze_with_labels!

    result = described_class.call(evaluation: evaluation)

    expect(result).not_to be_success
  end

  it "records identities, labels, verdicts, confusion counts, cost, and provenance" do
    freeze_with_labels!
    record_run(case_id: "A-01", verdict: "uncertain")
    record_run(case_id: "A-02", verdict: "within_scope")

    result = described_class.call(evaluation: evaluation)

    expect(result).to be_success
    report = result.report
    expect(report.fetch("policy")).to eq("solo")
    expect(report.fetch("solo_maintainer")).to eq(owner.email)
    expect(report.dig("provenance", "manifest_digest")).to eq(evaluation.manifest_digest)
    expect(report.dig("provenance", "manifest_digest_matches_current")).to be(true)
    expect(report.dig("measures", "false_alarms")).to eq("100.0% (1 / 1)")
    expect(report.dig("measures", "missed_material_drift")).to eq("100.0% (1 / 1)")
    expect(report.dig("measures", "confusion_counts", "within_scope")).to eq([ 0, 0, 1 ])
    expect(report.dig("measures", "review_cost_cents")).to eq(50)
  end

  it "states the solo assurance limits and keeps production measures explicitly unestablished" do
    freeze_with_labels!
    record_run(case_id: "A-01", verdict: "within_scope")
    record_run(case_id: "A-02", verdict: "within_scope")

    report = described_class.call(evaluation: evaluation).report

    expect(report.fetch("assurance_limits")).to include("no independence")
    expect(report.dig("measures", "escaped_changes")).to include("not established")
    expect(report.dig("measures", "delivery_baseline")).to include("not established")
    expect(report.dig("measures", "rework")).to include("not established")
    expect(report.dig("measures", "human_time")).to include("not established")
    expect(report.fetch("promotion_decision")).to include("not established")
    expect(evaluation.reload.report_markdown).to include("Solo-Maintainer Shadow Evaluation Report")
  end

  # @spec PARTIAL-CLOSEOUT-031
  it "reassesses only the submitted originating prerequisite when its report compiles" do
    issue = create(:issue, project: project)
    notification = create(:notification, :error, account: account, subject: issue,
      source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE, blocking: true,
      metadata: { "prerequisites" => [ { "criterion" => "measured rollout", "next_step" => "Run the evaluation.", "status" => "awaiting_evidence" } ] })
    PartialCloseouts::SubmitEvidence.call(notification:, actor: owner, criterion: "measured rollout", kind: "evaluation_report",
      reference: "shadow-evaluation:#{evaluation.id}", revision: evaluation.manifest_digest,
      explanation: "This report is the requested measured-rollout evidence.")
    freeze_with_labels!
    record_run(case_id: "A-01", verdict: "within_scope")
    record_run(case_id: "A-02", verdict: "within_scope")
    allow(AgentHarness).to receive(:send_message).and_return(double(success?: true,
      output: '{"outcome":"insufficient","reasoning":"Production measures remain unestablished."}'))

    described_class.call(evaluation: evaluation)

    prerequisite = notification.reload.metadata.fetch("prerequisites").first
    expect(prerequisite).to include("outcome" => "insufficient", "status" => "awaiting_evidence")
    expect(notification).to be_active
  end

  it "keeps review cost unestablished when an evaluated run lacks cost provenance" do
    freeze_with_labels!
    record_run(case_id: "A-01", verdict: "within_scope", cost_cents: 25)
    record_run(case_id: "A-02", verdict: "within_scope", cost_cents: 0)

    report = described_class.call(evaluation: evaluation).report

    expect(report.dig("measures", "review_cost_cents")).to include("not established")
  end

  it "keeps post-result revisions out of the blinded scores and lists them separately" do
    freeze_with_labels!
    record_run(case_id: "A-01", verdict: "within_scope")
    record_run(case_id: "A-02", verdict: "within_scope")
    revision = IntentConformance::ShadowEvaluation::ReviseLabel.call(evaluation: evaluation, actor: owner, case_id: "A-02",
      revised_outcome: "within_scope", reason: "reviewer cited a non-binding implementation choice")
    expect(revision).to be_success

    result = described_class.call(evaluation: evaluation)

    # Original A-02 label (material_drift) still drives missed-drift scoring.
    expect(result.report.dig("measures", "missed_material_drift")).to eq("100.0% (1 / 1)")
    revised_entry = result.report.fetch("cases").find { |entry| entry.fetch("case_id") == "A-02" }
    expect(revised_entry.dig("revision", "revised")).to eq("within_scope")
    expect(revised_entry.dig("revision", "original")).to eq("material_drift")
    expect(revised_entry.fetch("reference_label")).to eq("material_drift")
  end

  it "counts not-evaluated cases explicitly instead of treating them as agreement" do
    freeze_with_labels!
    record_run(case_id: "A-01", verdict: "not_evaluated", failure_reason: "invalid_json")
    record_run(case_id: "A-02", verdict: "within_scope")

    report = described_class.call(evaluation: evaluation).report

    expect(report.dig("measures", "not_evaluated_cases")).to eq(1)
    expect(report.dig("measures", "false_alarms")).to include("not established")
  end

  it "flags when the corpus manifest changed after this evidence generation" do
    freeze_with_labels!
    record_run(case_id: "A-01", verdict: "within_scope")
    record_run(case_id: "A-02", verdict: "within_scope")
    File.write(manifest_path, { "cases" => cases + [ corpus_case("A-99") ] }.to_yaml)

    report = described_class.call(evaluation: evaluation).report

    expect(report.dig("provenance", "manifest_digest_matches_current")).to be(false)
  end
end
