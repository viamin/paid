# frozen_string_literal: true

require "rails_helper"

# @spec FACET-CONFIDENCE-008 FACET-CONFIDENCE-009 FACET-CONFIDENCE-010
# @spec FACET-CONFIDENCE-011 FACET-CONFIDENCE-012 CONFIDENCE-DELIVERY-003
# @spec CONFIDENCE-DELIVERY-014
RSpec.describe FeatureIntents::ScopedReadiness do
  let(:project) { create(:project) }

  def assessment(intent: 80, technical: 80, status: "completed", evidence_revision: "evidence-v1")
    { status:, intent_score: intent, technical_score: technical, evidence_revision: }
  end

  def mapping(prerequisites: [ { id: "scope", assessment: assessment } ], coverage: "complete", scope_revision: "scope-v1",
    design_artifacts: [ { path: "docs/intent/example.md", required: true, merged: true, scope_revision: "scope-v1", revision: "a" * 40 } ])
    {
      coverage:,
      scope_revision:,
      prerequisites:,
      design_artifacts:
    }
  end

  it "passes exactly at the independent default thresholds and retains its inputs" do
    result = described_class.call(project:, mapping: mapping)

    expect(result).to be_ready
    expect(result.snapshot).to include(
      "thresholds" => { "intent" => 80, "technical" => 80 },
      "scope_revision" => "scope-v1"
    )
    expect(result.snapshot.fetch("prerequisites").first).to include("evidence_revision" => "evidence-v1")
  end

  it "retains the normalized coverage assessment used to evaluate readiness" do
    explicit_coverage = described_class.call(project:, mapping: mapping)
    legacy_coverage = described_class.call(project:, mapping: mapping.merge(coverage: nil, coverage_complete: true))
    unknown_coverage = described_class.call(project:, mapping: mapping(coverage: "unknown"))

    expect(explicit_coverage.snapshot.fetch("coverage")).to eq("complete")
    expect(legacy_coverage.snapshot.fetch("coverage")).to eq("complete")
    expect(unknown_coverage.snapshot.fetch("coverage")).to eq("unknown")
  end

  it "does not treat a completed empty prerequisite mapping as ready" do
    result = described_class.call(project:, mapping: mapping(prerequisites: []))

    expect(result).not_to be_ready
    expect(result.blockers.map(&:code)).to include("prerequisite_mapping_empty")
  end

  it "fails each independent 79/80 boundary without averaging scores" do
    result = described_class.call(project:, mapping: mapping(prerequisites: [
      { id: "intent", assessment: assessment(intent: 79, technical: 100) },
      { id: "technical", assessment: assessment(intent: 100, technical: 79) }
    ]))

    expect(result).not_to be_ready
    expect(result.blockers.map(&:code)).to contain_exactly("intent_below_threshold", "technical_below_threshold")
  end

  it "fails assessments with scores outside the bounded finite 0-100 range" do
    result = described_class.call(project:, mapping: mapping(prerequisites: [
      { id: "out-of-range", assessment: assessment(intent: 101, technical: Float::INFINITY) }
    ]))

    expect(result).not_to be_ready
    expect(result.blockers.map(&:code)).to contain_exactly("intent_invalid", "technical_invalid")
  end

  it "uses independently configured project thresholds" do
    project.update!(intent_threshold: 70, technical_threshold: 90)

    result = described_class.call(project:, mapping: mapping(prerequisites: [
      { id: "scope", assessment: assessment(intent: 70, technical: 90) }
    ]))

    expect(result).to be_ready
    expect(result.snapshot.fetch("thresholds")).to eq("intent" => 70, "technical" => 90)
  end

  it "fails visibly for missing coverage, assessments, and superseded evidence" do
    missing_coverage = described_class.call(project:, mapping: mapping(coverage: "unknown", prerequisites: []))
    missing_assessment = described_class.call(project:, mapping: mapping(prerequisites: [ { id: "scope" } ]))
    pending = described_class.call(project:, mapping: mapping(prerequisites: [ { id: "scope", assessment: assessment(status: "pending") } ]))
    stale = described_class.call(project:, mapping: mapping(prerequisites: [
      { id: "scope", assessment: assessment.merge(current_evidence_revision: "evidence-v2") }
    ]))

    expect(missing_coverage.blockers.map(&:code)).to include("prerequisite_coverage_unknown")
    expect(missing_assessment.blockers.map(&:code)).to include("assessment_missing")
    expect(pending.blockers.map(&:code)).to include("assessment_pending")
    expect(stale.blockers.map(&:code)).to include("assessment_superseded")
  end

  it "fails visibly instead of raising for malformed prerequisite entries" do
    null_entry = described_class.call(project:, mapping: mapping(prerequisites: [ nil ]))
    scalar_entry = described_class.call(project:, mapping: mapping(prerequisites: [ "scope" ]))
    malformed_assessment = described_class.call(project:, mapping: mapping(prerequisites: [ { id: "scope", assessment: "completed" } ]))

    expect(null_entry.blockers.map(&:code)).to include("prerequisite_invalid")
    expect(scalar_entry.blockers.map(&:code)).to include("prerequisite_invalid")
    expect(malformed_assessment.blockers.map(&:code)).to include("assessment_invalid")
  end

  it "fails closed for a malformed mapping payload" do
    result = described_class.call(project:, mapping: "not a mapping")

    expect(result).not_to be_ready
    expect(result.blockers.map(&:code)).to include("prerequisite_coverage_unknown", "scope_revision_unknown")
  end

  it "fails an unmerged or scope-contradicting relevant design artifact" do
    unmerged = described_class.call(project:, mapping: mapping(design_artifacts: [
      { path: "docs/intent/example.md", required: true, merged: false, scope_revision: "scope-v1" }
    ]))
    contradictory = described_class.call(project:, mapping: mapping(design_artifacts: [
      { path: "docs/intent/example.md", required: true, merged: true, revision: "a" * 40, scope_revision: "old-scope" }
    ]))

    expect(unmerged.blockers.map(&:code)).to include("design_artifact_unmerged")
    expect(contradictory.blockers.map(&:code)).to include("design_artifact_scope_mismatch")
  end

  it "fails visibly for malformed design artifact entries" do
    result = described_class.call(project:, mapping: mapping(design_artifacts: [ nil, "docs/intent/example.md" ]))

    expect(result.blockers.map(&:code)).to include("design_artifact_invalid")
  end

  it "fails when the issue or required design artifact lacks a scope revision" do
    missing_issue_scope = described_class.call(project:, mapping: mapping(scope_revision: nil))
    missing_artifact_scope = described_class.call(project:, mapping: mapping(design_artifacts: [
      { path: "docs/intent/example.md", required: true, merged: true, revision: "a" * 40 }
    ]))

    expect(missing_issue_scope.blockers.map(&:code)).to include("scope_revision_unknown")
    expect(missing_artifact_scope.blockers.map(&:code)).to include("design_artifact_scope_unknown")
  end

  it "assesses a research issue only through its mapped investigation prerequisites" do
    result = described_class.call(project:, mapping: mapping(prerequisites: [
      { id: "investigation-method", assessment: assessment(intent: 80, technical: 80) }
    ]).merge(issue_kind: "research", unrelated_prerequisites: [
      { id: "implementation-answer", assessment: assessment(intent: nil, technical: nil) }
    ]))

    expect(result).to be_ready
  end

  it "marks a passing assessment as releasable now that the RDR-071 release path is live" do
    result = described_class.call(project:, mapping: mapping)

    expect(result).to be_ready
    expect(result).not_to be_shadow_only
    expect(result).to be_releasable
  end
end
