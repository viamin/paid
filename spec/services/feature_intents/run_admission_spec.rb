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
    expect(result.code).to eq("feature_not_released")
    expect(result.reason).to include("not released")
  end

  it "distinguishes a revising feature hold" do
    feature = create(:feature_intent, project: project, status: "revising")
    create(:feature_intent_issue, feature_intent: feature, issue: issue)

    result = described_class.call(issue: issue)

    expect(result).not_to be_allowed
    expect(result.code).to eq("feature_revising")
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

    result = described_class.call(issue: issue)

    expect(result).not_to be_allowed
    expect(result.code).to eq("no_approved_revision")
  end

  it "admits a planning task without treating the design it prepares as implementation approval" do # @spec CONFIDENCE-DELIVERY-017
    feature = create(:feature_intent, project: project, status: "approved_waiting_for_merge")
    create(:feature_intent_issue, feature_intent: feature, issue: issue,
      readiness_mapping: planning_hold_contract)

    expect(described_class.call(issue: issue)).to be_allowed
  end

  it "denies released work while an issue dependency remains open" do # @spec FEATURE-APPROVAL-023 @spec CONFIDENCE-DELIVERY-005
    feature = create(:feature_intent, project: project)
    create(:feature_intent_issue, feature_intent: feature, issue: issue)
    blocker = create(:issue, project: project, github_state: "open")
    create(:issue_dependency, issue: issue, depends_on_issue: blocker)

    result = described_class.call(issue: issue)

    expect(result).not_to be_allowed
    expect(result.code).to eq("issue_dependencies_incomplete")
    expect(result.reason).to include("unresolved dependencies")
  end

  it "holds a tree issue until its recorded in-tree prerequisite completes" do
    feature = create(:feature_intent, project: project)
    prerequisite_issue = create(:issue, project: project, github_state: "open")
    prerequisite_link = create(:feature_intent_issue, feature_intent: feature, issue: prerequisite_issue)
    link = create(:feature_intent_issue, feature_intent: feature, issue: issue)
    create(:feature_intent_issue_dependency, feature_intent_issue: link,
      depends_on_feature_intent_issue: prerequisite_link)

    result = described_class.call(issue: issue)

    expect(result).not_to be_allowed
    expect(result.code).to eq("in_tree_dependency_incomplete")

    prerequisite_issue.update!(github_state: "closed")

    expect(described_class.call(issue: issue)).to be_allowed
  end

  it "admits a standalone call without lazy-loading each in-tree dependency's issue" do # @spec FEATURE-APPROVAL-024
    feature = create(:feature_intent, project: project)
    link = create(:feature_intent_issue, feature_intent: feature, issue: issue)
    3.times do
      prerequisite_link = create(:feature_intent_issue, feature_intent: feature,
        issue: create(:issue, project: project, github_state: "open"))
      create(:feature_intent_issue_dependency, feature_intent_issue: link,
        depends_on_feature_intent_issue: prerequisite_link)
    end

    queries = []
    subscriber = ->(*args) { queries << ActiveSupport::Notifications::Event.new(*args).payload[:sql] }
    result = nil
    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
      result = described_class.call(issue: issue)
    end

    expect(result).not_to be_allowed
    expect(queries.grep(/FROM "issues" WHERE "issues"\."id" = /)).to be_empty
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

  it "reconciles a changed unstarted scope before admission" do # @spec CONFIDENCE-DELIVERY-009
    feature = create(:feature_intent, :confidence_driven, project: project)
    changed_mapping = confidence_mapping.deep_merge(
      "scope_revision" => "scope-v2",
      "design_artifacts" => [ { "path" => "docs/intent/example.md", "required" => true, "merged" => true, "scope_revision" => "scope-v2", "revision" => "b" * 40 } ]
    )
    link = create(:feature_intent_issue, feature_intent: feature, issue: issue,
      release_state: "released",
      readiness_mapping: changed_mapping,
      release_snapshot: confidence_snapshot)

    result = described_class.call(issue: issue)

    expect(result).to be_allowed
    expect(result.revision).to eq("b" * 40)
    expect(link.reload.release_snapshot).to include("scope_revision" => "scope-v2")
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
      "planning_hold" => {
        "owner" => "paid", "task_kind" => "implementation", "operator_override" => false,
        "reason" => "Awaiting scoped readiness.", "release_condition" => "Scoped readiness passes.",
        "provenance" => { "source" => "publish_held_issue" }
      },
      "prerequisites" => [
        { "id" => "intent", "assessment" => { "status" => "completed", "evidence_revision" => "evidence-v1", "intent_score" => 80, "technical_score" => 80 } }
      ],
      "design_artifacts" => [ { "path" => "docs/intent/example.md", "required" => true, "merged" => true, "scope_revision" => "scope-v1", "revision" => "a" * 40 } ]
    }
  end

  def confidence_snapshot
    FeatureIntents::ScopedReadiness.call(project: project, mapping: confidence_mapping).snapshot
  end

  def planning_hold_contract
    {
      "planning_hold" => {
        "owner" => "paid",
        "task_kind" => "planning",
        "operator_override" => false,
        "reason" => "Prepare the design evidence for this task.",
        "release_condition" => "The planning task itself is admitted; implementation remains gated by its own readiness.",
        "scope_revision" => "scope-v1",
        "provenance" => { "source" => "publish_held_issue" }
      }
    }
  end
end
