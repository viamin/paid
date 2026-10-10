# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("lib/intent_conformance/shadow_evaluation_worksheet")

# @spec INTENT-CONFORMANCE-ROLLOUT-003
RSpec.describe IntentConformance::ShadowEvaluationWorksheet, :no_db do
  let(:manifest) { Rails.root.join("tmp/shadow-worksheet-manifest.yml") }
  let(:ledger) { Rails.root.join("tmp/shadow-worksheet-ledger.jsonl") }
  let(:commit) { "a" * 40 }
  let(:base_event) { { "manifest_commit" => commit } }

  before do
    File.write(manifest, { "cases" => [ { "id" => "A-01" }, { "id" => "A-02" } ] }.to_yaml)
    File.delete(ledger) if File.exist?(ledger)
  end

  after { [ manifest, ledger ].each { |path| File.delete(path) if File.exist?(path) } }

  it "computes false alarms, missed material drift, and review cost across an agreeing pair and a tie-broken pair" do
    File.write(ledger, events.map { |event| JSON.generate(event) }.join("\n"))

    worksheet = described_class.compile(manifest_path: manifest, ledger_path: ledger, manifest_commit: commit)

    expect(worksheet).to include("| False alarms | 0.0% (0 / 1) | adjudication + shadow_run |")
    expect(worksheet).to include("| Missed material drift | 100.0% (1 / 1) | adjudication + shadow_run |")
    expect(worksheet).to include("| Review cost | 150 cents | shadow_run |")
  end

  # @spec INTENT-CONFORMANCE-ROLLOUT-003
  it "resolves the majority verdict regardless of adjudication order" do
    agreement = [ { "verdict" => "accepted" }, { "verdict" => "accepted" } ]
    tie_break = [ { "verdict" => "accepted" }, { "verdict" => "material_drift" }, { "verdict" => "accepted" } ]

    expect(described_class.majority_verdict(agreement)).to eq("accepted")
    expect(described_class.majority_verdict(tie_break)).to eq("accepted")
    expect(described_class.majority_verdict(tie_break.reverse)).to eq("accepted")
  end

  def events
    [
      base_event.merge("type" => "operators_frozen", "event_id" => "freeze", "operators" => %w[op-a op-b op-c], "recorded_at" => "2026-10-10T08:00:00Z"),
      # A-01: operators agree (accepted); reviewer correctly says within_scope -> no false alarm.
      base_event.merge("type" => "adjudication", "event_id" => "a01-1", "case_id" => "A-01", "operator" => "op-a", "verdict" => "accepted", "cited_design_claim" => "X", "reason" => "Y", "recorded_at" => "2026-10-10T08:01:00Z"),
      base_event.merge("type" => "adjudication", "event_id" => "a01-2", "case_id" => "A-01", "operator" => "op-b", "verdict" => "accepted", "cited_design_claim" => "X", "reason" => "Y", "recorded_at" => "2026-10-10T08:02:00Z"),
      # A-02: operators disagree and a third breaks the tie toward material_drift; reviewer misses it (within_scope).
      base_event.merge("type" => "adjudication", "event_id" => "a02-1", "case_id" => "A-02", "operator" => "op-a", "verdict" => "material_drift", "cited_design_claim" => "X", "reason" => "Y", "recorded_at" => "2026-10-10T08:03:00Z"),
      base_event.merge("type" => "adjudication", "event_id" => "a02-2", "case_id" => "A-02", "operator" => "op-b", "verdict" => "accepted", "cited_design_claim" => "X", "reason" => "Y", "recorded_at" => "2026-10-10T08:04:00Z"),
      base_event.merge("type" => "adjudication", "event_id" => "a02-3", "case_id" => "A-02", "operator" => "op-c", "verdict" => "material_drift", "cited_design_claim" => "X", "reason" => "Y", "recorded_at" => "2026-10-10T08:05:00Z"),
      base_event.merge("type" => "shadow_run", "event_id" => "run-a01", "case_id" => "A-01", "reviewer_run_id" => "run-1", "reviewer_model" => "model", "prompt_digest" => "digest", "verdict" => "within_scope", "cost_cents" => 100, "recorded_at" => "2026-10-10T09:00:00Z"),
      base_event.merge("type" => "shadow_run", "event_id" => "run-a02", "case_id" => "A-02", "reviewer_run_id" => "run-2", "reviewer_model" => "model", "prompt_digest" => "digest", "verdict" => "within_scope", "cost_cents" => 50, "recorded_at" => "2026-10-10T09:01:00Z")
    ]
  end
end
