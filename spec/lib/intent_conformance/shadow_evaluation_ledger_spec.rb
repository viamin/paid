# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("lib/intent_conformance/shadow_evaluation_ledger")

RSpec.describe IntentConformance::ShadowEvaluationLedger, :no_db do
  let(:manifest) { Rails.root.join("tmp/shadow-manifest.yml") }
  let(:ledger) { Rails.root.join("tmp/shadow-ledger.jsonl") }
  let(:base_event) { { "manifest_commit" => "a" * 40, "recorded_at" => "2026-10-10T12:00:00Z" } }

  before do
    File.write(manifest, { "cases" => [ { "id" => "A-01" } ] }.to_yaml)
    File.delete(ledger) if File.exist?(ledger)
  end

  after { [ manifest, ledger ].each { |path| File.delete(path) if File.exist?(path) } }

  it "refuses shadow execution while adjudications are absent" do
    expect { described_class.ready_for_shadow_run!(manifest_path: manifest, ledger_path: ledger, manifest_commit: "a" * 40) }
      .to raise_error(IntentConformance::ShadowEvaluationLedger::PendingHumanInput, /pending human input/)
  end

  it "rejects non-independent paired adjudications" do
    events = [
      base_event.merge("type" => "operators_frozen", "event_id" => "freeze", "operators" => %w[one two three]),
      base_event.merge("type" => "adjudication", "event_id" => "one", "case_id" => "A-01", "operator" => "one", "verdict" => "accepted", "cited_design_claim" => "X", "reason" => "Y"),
      base_event.merge("type" => "adjudication", "event_id" => "two", "case_id" => "A-01", "operator" => "one", "verdict" => "accepted", "cited_design_claim" => "X", "reason" => "Y")
    ]
    File.write(ledger, events.map { |event| JSON.generate(event) }.join("\n"))
    expect { described_class.ready_for_shadow_run!(manifest_path: manifest, ledger_path: ledger, manifest_commit: "a" * 40) }.to raise_error(/independent/)
  end

  it "rejects a manifest identity that was not frozen before adjudication" do
    File.write(ledger, JSON.generate(base_event.merge("type" => "adjudication", "event_id" => "one")))
    expect { described_class.ready_for_shadow_run!(manifest_path: manifest, ledger_path: ledger, manifest_commit: "b" * 40) }.to raise_error(/committed before/)
  end

  it "refuses worksheet compilation until human input and reviewer events exist" do
    require Rails.root.join("lib/intent_conformance/shadow_evaluation_worksheet")
    expect {
      IntentConformance::ShadowEvaluationWorksheet.compile(manifest_path: manifest, ledger_path: ledger, manifest_commit: "a" * 40)
    }.to raise_error(IntentConformance::ShadowEvaluationLedger::PendingHumanInput, /pending human input/)
  end
end
