# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("lib/intent_conformance/shadow_evaluation_policy")

# @spec INTENT-CONFORMANCE-ROLLOUT-005
# @spec INTENT-CONFORMANCE-ROLLOUT-006
# @spec INTENT-CONFORMANCE-ROLLOUT-008
RSpec.describe IntentConformance::ShadowEvaluationPolicy, :no_db do
  let(:cases) { [ { "id" => "A-01" }, { "id" => "A-02" } ] }
  let(:declaration_event) do
    { "type" => "evaluation_policy", "policy" => "solo", "maintainer" => "maintainer@paid", "recorded_at" => "2026-10-23T10:00:00Z" }
  end

  def adjudication(case_id:, operator: "maintainer@paid", verdict: "within_scope", recorded_at: "2026-10-23T11:00:00Z")
    { "type" => "adjudication", "case_id" => case_id, "operator" => operator, "verdict" => verdict,
      "cited_design_claim" => "claim", "reason" => "reason", "recorded_at" => recorded_at }
  end

  def shadow_run(case_id:, verdict: "within_scope")
    { "type" => "shadow_run", "case_id" => case_id, "reviewer_run_id" => "run-#{case_id}", "reviewer_model" => "model",
      "prompt_digest" => "digest", "verdict" => verdict, "cost_cents" => 1, "recorded_at" => "2026-10-23T12:00:00Z" }
  end

  describe "policy declaration" do
    it "defaults to the team policy when no declaration exists" do
      expect(described_class.policy_for([])).to eq("team")
      expect(described_class.solo?([adjudication(case_id: "A-01", operator: "someone-else")])).to be(false)
    end

    it "parses an explicit solo declaration" do
      declaration = described_class.declaration_for([declaration_event])
      expect(declaration.solo?).to be(true)
      expect(declaration.maintainer).to eq("maintainer@paid")
    end

    it "rejects a declaration without a named maintainer" do
      event = declaration_event.merge("maintainer" => "")
      expect { described_class.declaration_for([event]) }
        .to raise_error(IntentConformance::ShadowEvaluationLedger::InvalidLedger, /must name its single maintainer/)
    end

    it "rejects an unknown policy" do
      event = declaration_event.merge("policy" => "auto")
      expect { described_class.declaration_for([event]) }
        .to raise_error(IntentConformance::ShadowEvaluationLedger::InvalidLedger, /policy in team\|solo/)
    end

    it "rejects a duplicate declaration" do
      expect { described_class.declaration_for([declaration_event, declaration_event]) }
        .to raise_error(IntentConformance::ShadowEvaluationLedger::InvalidLedger, /at most one evaluation_policy/)
    end

    it "rejects a declaration appended after an adjudication" do
      entries = [adjudication(case_id: "A-01"), declaration_event.merge("recorded_at" => "2026-10-23T09:00:00Z")]
      expect { described_class.ensure_declaration!(entries) }
        .to raise_error(IntentConformance::ShadowEvaluationLedger::InvalidLedger, /must precede adjudications/)
    end

    it "rejects an adjudication recorded before the declaration" do
      entries = [declaration_event, adjudication(case_id: "A-01", recorded_at: "2026-10-23T09:59:00Z")]
      expect { described_class.ensure_declaration!(entries) }
        .to raise_error(IntentConformance::ShadowEvaluationLedger::InvalidLedger, /recorded before the policy declaration/)
    end
  end

  describe "solo adjudications" do
    it "accepts one complete adjudication per case from the declared maintainer" do
      entries = [declaration_event, adjudication(case_id: "A-01"), adjudication(case_id: "A-02", verdict: "material_drift")]
      expect(described_class.ensure_solo_adjudications!(cases, entries)).to be(true)
    end

    it "keeps pending human input while a case is unlabeled" do
      entries = [declaration_event, adjudication(case_id: "A-01")]
      expect { described_class.ensure_solo_adjudications!(cases, entries) }
        .to raise_error(IntentConformance::ShadowEvaluationLedger::PendingHumanInput, /A-02 needs the maintainer/)
    end

    it "rejects an adjudication by anyone other than the declared maintainer" do
      entries = [declaration_event, adjudication(case_id: "A-01", operator: "bot"), adjudication(case_id: "A-02")]
      expect { described_class.ensure_solo_adjudications!(cases, entries) }
        .to raise_error(IntentConformance::ShadowEvaluationLedger::InvalidLedger, /declared maintainer/)
    end

    it "rejects more than one solo adjudication for a case" do
      entries = [declaration_event, adjudication(case_id: "A-01"), adjudication(case_id: "A-01", verdict: "uncertain"), adjudication(case_id: "A-02")]
      expect { described_class.ensure_solo_adjudications!(cases, entries) }
        .to raise_error(IntentConformance::ShadowEvaluationLedger::InvalidLedger, /more than one solo adjudication/)
    end

    it "rejects an incomplete adjudication" do
      event = adjudication(case_id: "A-01").merge("reason" => "")
      entries = [declaration_event, event, adjudication(case_id: "A-02")]
      expect { described_class.ensure_solo_adjudications!(cases, entries) }
        .to raise_error(IntentConformance::ShadowEvaluationLedger::InvalidLedger, /incomplete/)
    end

    it "rejects solo adjudications without a declaration" do
      expect { described_class.ensure_solo_adjudications!(cases, [adjudication(case_id: "A-01")]) }
        .to raise_error(IntentConformance::ShadowEvaluationLedger::InvalidLedger, /require a solo evaluation_policy declaration/)
    end
  end

  describe "skipped cases" do
    it "accepts a skip event but never counts it as an adjudication" do
      skip_event = { "type" => "case_skipped", "case_id" => "A-01", "operator" => "maintainer@paid", "recorded_at" => "2026-10-23T11:30:00Z" }
      expect(described_class.ensure_skips!(cases, [skip_event])).to be_nil

      entries = [declaration_event, skip_event, adjudication(case_id: "A-02")]
      expect { described_class.ensure_solo_adjudications!(cases, entries) }
        .to raise_error(IntentConformance::ShadowEvaluationLedger::PendingHumanInput, /A-01 needs the maintainer/)
    end

    it "rejects a skip for an unknown case" do
      event = { "type" => "case_skipped", "case_id" => "NOPE", "operator" => "maintainer@paid", "recorded_at" => "2026-10-23T11:30:00Z" }
      expect { described_class.ensure_skips!(cases, [event]) }
        .to raise_error(IntentConformance::ShadowEvaluationLedger::InvalidLedger, /outside the frozen manifest/)
    end
  end

  describe "post-result label revisions" do
    it "accepts a reasoned revision appended after the case's shadow run" do
      entries = [
        declaration_event,
        adjudication(case_id: "A-01"),
        adjudication(case_id: "A-02"),
        shadow_run(case_id: "A-01", verdict: "material_drift"),
        { "type" => "label_revision", "case_id" => "A-01", "operator" => "maintainer@paid", "original_verdict" => "within_scope",
          "revised_verdict" => "material_drift", "reason" => "reviewer cited a constraint I missed", "recorded_at" => "2026-10-23T13:00:00Z" }
      ]
      expect(described_class.ensure_label_revisions!(cases, entries)).to be_nil
    end

    it "rejects a revision recorded before the case's shadow run" do
      entries = [
        declaration_event,
        adjudication(case_id: "A-01"),
        adjudication(case_id: "A-02"),
        { "type" => "label_revision", "case_id" => "A-01", "operator" => "maintainer@paid", "original_verdict" => "within_scope",
          "revised_verdict" => "material_drift", "reason" => "premature", "recorded_at" => "2026-10-23T11:00:00Z" }
      ]
      expect { described_class.ensure_label_revisions!(cases, entries) }
        .to raise_error(IntentConformance::ShadowEvaluationLedger::InvalidLedger, /must follow the case's shadow run/)
    end

    it "rejects a revision whose original_verdict does not match the frozen label" do
      entries = [
        declaration_event,
        adjudication(case_id: "A-01"),
        adjudication(case_id: "A-02"),
        shadow_run(case_id: "A-01"),
        { "type" => "label_revision", "case_id" => "A-01", "operator" => "maintainer@paid", "original_verdict" => "uncertain",
          "revised_verdict" => "material_drift", "reason" => "mismatched", "recorded_at" => "2026-10-23T13:00:00Z" }
      ]
      expect { described_class.ensure_label_revisions!(cases, entries) }
        .to raise_error(IntentConformance::ShadowEvaluationLedger::InvalidLedger, /does not match the frozen reference label/)
    end
  end

  describe "persisted reference-label freezing" do
    let(:declaration) { described_class.declaration_for([declaration_event]) }

    def label_row(case_id:, state: "labeled", verdict: "within_scope", operator: "maintainer@paid", claim: "claim", reason: "reason")
      { "case_id" => case_id, "state" => state, "verdict" => verdict, "operator" => operator,
        "cited_design_claim" => claim, "reason" => reason }
    end

    it "accepts a complete solo label set" do
      labels = [label_row(case_id: "A-01"), label_row(case_id: "A-02", verdict: "material_drift")]
      expect(described_class.validate_reference_labels!(cases: cases, labels: labels, declaration: declaration)).to be(true)
    end

    it "refuses to freeze while a case is unlabeled or skipped" do
      labels = [label_row(case_id: "A-01"), label_row(case_id: "A-02", state: "skipped", verdict: nil, claim: nil, reason: nil)]
      expect { described_class.validate_reference_labels!(cases: cases, labels: labels, declaration: declaration) }
        .to raise_error(IntentConformance::ShadowEvaluationLedger::PendingHumanInput, /A-02 is unlabeled or skipped/)
    end

    it "refuses a label recorded by a different operator" do
      labels = [label_row(case_id: "A-01", operator: "someone-else"), label_row(case_id: "A-02")]
      expect { described_class.validate_reference_labels!(cases: cases, labels: labels, declaration: declaration) }
        .to raise_error(IntentConformance::ShadowEvaluationLedger::InvalidLedger, /declared maintainer/)
    end

    it "requires a solo declaration" do
      expect { described_class.validate_reference_labels!(cases: cases, labels: [], declaration: nil) }
        .to raise_error(IntentConformance::ShadowEvaluationLedger::InvalidLedger, /solo declaration is required/)
    end
  end
end
