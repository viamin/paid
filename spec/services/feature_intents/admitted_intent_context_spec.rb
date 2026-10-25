# frozen_string_literal: true

require "rails_helper"

# @spec FACET-CONFIDENCE-013 @spec FACET-CONFIDENCE-015
# @spec CONFIDENCE-DELIVERY-007 @spec CONFIDENCE-DELIVERY-010
RSpec.describe FeatureIntents::AdmittedIntentContext do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, project: project) }
  let(:feature) { create(:feature_intent, :confidence_driven, project: project) }

  # Production release snapshots come from ScopedReadiness via ReleaseIssue and
  # carry no dedicated merged_baseline key; the first design artifact's merged
  # revision is the baseline handed to builders.
  let!(:link) do
    create(:feature_intent_issue, feature_intent: feature, issue: issue,
      release_state: "released", release_snapshot: released_snapshot)
  end

  def released_snapshot
    FeatureIntents::ScopedReadiness.call(project: project, mapping: {
      "coverage" => "complete",
      "scope_revision" => "scope-v1",
      "prerequisites" => [
        { "id" => "intent", "assessment" => { "status" => "completed", "evidence_revision" => "evidence-v1", "intent_score" => 80, "technical_score" => 80 } }
      ],
      "design_artifacts" => [ { "path" => "docs/intent/example.md", "required" => true, "merged" => true, "scope_revision" => "scope-v1", "revision" => "a" * 40 } ]
    }).snapshot
  end

  it "prefers an explicit merged baseline when the release snapshot records one" do
    link.update!(release_snapshot: link.release_snapshot.merge("merged_baseline" => "b" * 40))

    expect(described_class.capture(issue: issue).fetch("design_baseline")).to eq("b" * 40)
  end

  it "pins the first confidence link by id when an issue serves several designs" do
    later_feature = create(:feature_intent, :confidence_driven, project: project)
    create(:feature_intent_issue, feature_intent: later_feature, issue: issue,
      release_state: "released", release_snapshot: released_snapshot.merge("merged_baseline" => "later-baseline"))

    snapshot = described_class.capture(issue: issue)

    expect(snapshot.fetch("feature_id")).to eq(feature.id)
    expect(snapshot.fetch("design_baseline")).to eq("a" * 40)
  end

  # @spec CONFIDENCE-DELIVERY-007
  it "pins mapped design paths from the release snapshot rather than the live readiness mapping" do
    link.update!(readiness_mapping: { "design_artifacts" => [ { "path" => "docs/intent/revised.md" } ] })

    snapshot = described_class.capture(issue: issue)

    expect(snapshot.fetch("design_document_paths")).to eq([ "docs/intent/example.md" ])
  end

  describe "facet evidence" do
    let!(:facet) { create(:feature_intent_facet, feature_intent: feature, issue: issue, evidence_revision: 1) }
    let!(:direction) { create(:feature_intent_facet_direction, feature_intent_facet: facet) }
    let!(:alternative) { create(:feature_intent_facet_direction, feature_intent_facet: facet, name: "Pointer support") }

    before do
      create(:feature_intent_facet_assessment, status: "completed", feature_intent_facet_direction: direction,
        evidence_revision: 1, intent_score: 92, technical_score: 84,
        inferred_fit: "The selected direction fits the admitted scope.", explanation: "Assessment explanation.")
      create(:feature_intent_facet_assessment, status: "completed", feature_intent_facet_direction: alternative,
        evidence_revision: 1, intent_score: 71, technical_score: 90, inferred_fit: "Possible but less aligned.")
      FeatureIntentFacetEvidence.create!(account: project.account, feature_intent_facet: facet,
        feature_intent_facet_direction: direction, statement: "Keep keyboard navigation.",
        source_type: "human_correction", source_reference: "comment-1", idempotency_key: "evidence-1",
        occurred_at: Time.current, evidence_revision: 1)
    end

    it "snapshots scored evidence and keeps it unchanged after later evidence arrives" do
      snapshot = described_class.capture(issue: issue)
      facet.update!(evidence_revision: 2)

      expect(snapshot.fetch("policy")).to eq("confidence_driven")
      expect(snapshot.dig("facets", 0, "intent_score")).to eq(92)
      expect(snapshot.dig("facets", 0, "technical_score")).to eq(84)
      expect(snapshot.dig("facets", 0, "expressed_intent")).to include("Keep keyboard navigation.")
      expect(snapshot.dig("facets", 0, "inferred_fit")).to eq("The selected direction fits the admitted scope.")
      directions = snapshot.fetch("facets").map { |entry| entry.fetch("direction") }
      expect(directions).to contain_exactly(direction.name, alternative.name)
      expect(snapshot.fetch("design_baseline")).to eq("a" * 40)
      expect(snapshot.dig("facets", 0, "evidence_revision")).to eq(1)
    end

    # @spec FACET-CONFIDENCE-013
    it "shows a directionless human correction in every active direction entry" do
      FeatureIntentFacetEvidence.create!(account: project.account, feature_intent_facet: facet,
        statement: "Correction: keyboard navigation is required.",
        source_type: "human_correction", source_reference: "chat-2", idempotency_key: "evidence-2",
        occurred_at: Time.current, evidence_revision: 2)
      facet.update!(evidence_revision: 2)

      entries = described_class.capture(issue: issue).fetch("facets")

      expect(entries.map { |entry| entry.fetch("direction") }).to contain_exactly(direction.name, alternative.name)
      expect(entries.map { |entry| entry.fetch("expressed_intent") })
        .to all(include("Correction: keyboard navigation is required."))
    end

    # @spec FACET-CONFIDENCE-013
    it "keeps earlier active statements visible when later evidence advances the revision" do
      FeatureIntentFacetEvidence.create!(account: project.account, feature_intent_facet: facet,
        statement: "Prototype run passed.",
        source_type: "experiment_result", source_reference: "run-1", idempotency_key: "evidence-3",
        occurred_at: Time.current, evidence_revision: 2)
      facet.update!(evidence_revision: 2)

      snapshot = described_class.capture(issue: issue)

      expect(snapshot.dig("facets", 0, "expressed_intent")).to include("Keep keyboard navigation.")
      expect(snapshot.dig("facets", 0, "demonstrated_feasibility")).to include("Prototype run passed.")
    end
  end
end
