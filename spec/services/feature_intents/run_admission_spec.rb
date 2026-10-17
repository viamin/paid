# frozen_string_literal: true

require "rails_helper"

# @spec FEATURE-APPROVAL-023 @spec FEATURE-APPROVAL-024 @spec CONFIDENCE-DELIVERY-003 @spec CONFIDENCE-DELIVERY-005
RSpec.describe FeatureIntents::RunAdmission do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, project: project) }

  it "holds an issue linked to a feature that has not been released" do
    feature = create(:feature_intent, project: project, status: "approved_waiting_for_merge")
    create(:feature_intent_issue, feature_intent: feature, issue: issue)

    result = described_class.call(issue: issue)

    expect(result).not_to be_allowed
    expect(result.reason).to include("not released")
  end

  it "admits a released feature only at its approved repository revision" do
    revision = "a" * 40
    feature = create(:feature_intent, project: project, approved_design_revision: revision)
    create(:feature_intent_issue, feature_intent: feature, issue: issue)

    result = described_class.call(issue: issue)

    expect(result).to be_allowed
    expect(result.revision).to eq(revision)
  end

  it "fails closed when a released feature has no recorded revision" do
    feature = create(:feature_intent, project: project, approved_design_revision: nil)
    create(:feature_intent_issue, feature_intent: feature, issue: issue)

    expect(described_class.call(issue: issue)).not_to be_allowed
  end

  it "denies released work while an issue dependency remains open" do # @spec FEATURE-APPROVAL-023 @spec CONFIDENCE-DELIVERY-005
    feature = create(:feature_intent, project: project)
    create(:feature_intent_issue, feature_intent: feature, issue: issue)
    blocker = create(:issue, project: project, github_state: "open")
    create(:issue_dependency, issue: issue, depends_on_issue: blocker)

    result = described_class.call(issue: issue)

    expect(result).not_to be_allowed
    expect(result.reason).to include("unresolved dependencies")
  end

  it "denies released work while a dependency is awaiting deployment" do # @spec FEATURE-APPROVAL-023 @spec CONFIDENCE-DELIVERY-005
    feature = create(:feature_intent, project: project)
    create(:feature_intent_issue, feature_intent: feature, issue: issue)
    blocker = create(:issue, :pull_request, project: project, github_state: "closed", deployed_at: nil)
    create(:issue_dependency, issue: issue, depends_on_issue: blocker, requires_deployment: true)

    expect(described_class.call(issue: issue)).not_to be_allowed
  end

  it "denies released work while an external dependency is unresolved" do # @spec FEATURE-APPROVAL-023 @spec CONFIDENCE-DELIVERY-005
    feature = create(:feature_intent, project: project)
    create(:feature_intent_issue, feature_intent: feature, issue: issue)
    create(:issue_dependency, issue: issue, depends_on_issue: nil,
      depends_on_owner: "org", depends_on_repo: "repo", depends_on_number: 42)

    expect(described_class.call(issue: issue)).not_to be_allowed
  end

  it "admits released confidence-driven work from its immutable readiness snapshot without reconciling again" do # @spec CONFIDENCE-DELIVERY-003 @spec CONFIDENCE-DELIVERY-005
    feature = create(:feature_intent, :confidence_driven, project: project)
    create(:feature_intent_issue, feature_intent: feature, issue: issue,
      release_state: "released",
      readiness_mapping: confidence_mapping,
      release_snapshot: confidence_snapshot)
    expect(project.client).not_to receive(:remove_label_from_issue)

    result = described_class.call(issue: issue)

    expect(result).to be_allowed
    expect(result.revision).to eq("a" * 40)
  end

  it "reconciles ready held confidence-driven work before admission" do # @spec CONFIDENCE-DELIVERY-003 @spec CONFIDENCE-DELIVERY-005
    issue.update!(labels: [ "planning" ])
    feature = create(:feature_intent, :confidence_driven, project: project)
    link = create(:feature_intent_issue, feature_intent: feature, issue: issue, readiness_mapping: confidence_mapping)
    allow(project.client).to receive(:remove_label_from_issue)

    result = described_class.call(issue: issue)

    expect(result).to be_allowed
    expect(link.reload.release_state).to eq("released")
  end

  it "keeps mixed-policy features on their own admission contracts" do # @spec CONFIDENCE-DELIVERY-001
    approval_issue = create(:issue, project: project)
    approval_feature = create(:feature_intent, project: project)
    confidence_feature = create(:feature_intent, :confidence_driven, project: project)
    create(:feature_intent_issue, feature_intent: approval_feature, issue: approval_issue)
    create(:feature_intent_issue, feature_intent: confidence_feature, issue: issue)

    expect(described_class.call(issue: approval_issue)).to be_allowed
    expect(described_class.call(issue: issue)).not_to be_allowed
  end

  it "fails closed when confidence work is missing a reconciled release or assessment" do
    feature = create(:feature_intent, :confidence_driven, project: project)
    create(:feature_intent_issue, feature_intent: feature, issue: issue)

    expect(described_class.call(issue: issue)).not_to be_allowed
  end

  it "requires every confidence design the issue serves to have released evidence" do
    released_feature = create(:feature_intent, :confidence_driven, project: project)
    create(:feature_intent_issue, feature_intent: released_feature, issue: issue,
      release_state: "released", readiness_mapping: confidence_mapping, release_snapshot: confidence_snapshot)
    held_feature = create(:feature_intent, :confidence_driven, project: project)
    create(:feature_intent_issue, feature_intent: held_feature, issue: issue)

    result = described_class.call(issue: issue)

    expect(result).not_to be_allowed
    expect(result.reason).to be_present
  end

  it "holds admission when any linked approval-gated design is unreleased" do
    approval_feature = create(:feature_intent, project: project, status: "approved_waiting_for_merge")
    create(:feature_intent_issue, feature_intent: approval_feature, issue: issue)
    confidence_feature = create(:feature_intent, :confidence_driven, project: project)
    create(:feature_intent_issue, feature_intent: confidence_feature, issue: issue,
      release_state: "released", readiness_mapping: confidence_mapping, release_snapshot: confidence_snapshot)

    expect(described_class.call(issue: issue)).not_to be_allowed
  end

  it "admits when every design permits, pinning the first linked baseline deterministically" do
    first_feature = create(:feature_intent, :confidence_driven, project: project)
    create(:feature_intent_issue, feature_intent: first_feature, issue: issue,
      release_state: "released",
      readiness_mapping: confidence_mapping,
      release_snapshot: confidence_snapshot.merge("merged_baseline" => "b" * 40))
    second_feature = create(:feature_intent, :confidence_driven, project: project)
    create(:feature_intent_issue, feature_intent: second_feature, issue: issue,
      release_state: "released", readiness_mapping: confidence_mapping, release_snapshot: confidence_snapshot)

    result = described_class.call(issue: issue)

    expect(result).to be_allowed
    expect(result.revision).to eq("b" * 40)
  end

  def confidence_mapping
    {
      "coverage" => "complete",
      "scope_revision" => "scope-v1",
      "prerequisites" => [
        { "id" => "intent", "assessment" => { "status" => "completed", "evidence_revision" => "evidence-v1", "intent_score" => 80, "technical_score" => 80 } }
      ],
      "design_artifacts" => [ { "path" => "docs/intent/example.md", "required" => true, "merged" => true, "scope_revision" => "scope-v1", "revision" => "a" * 40 } ]
    }
  end

  def confidence_snapshot
    FeatureIntents::ScopedReadiness.call(project: project, mapping: confidence_mapping).snapshot
  end
end
