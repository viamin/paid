# frozen_string_literal: true

require "rails_helper"

# @spec CONFIDENCE-DELIVERY-003 @spec CONFIDENCE-DELIVERY-004 @spec CONFIDENCE-DELIVERY-006 @spec CONFIDENCE-DELIVERY-009
RSpec.describe FeatureIntents::ReleaseIssue do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, project: project, labels: [ "planning", "human-hold" ]) }
  let(:feature) { create(:feature_intent, :confidence_driven, project: project) }
  let(:mapping) do
    {
      "coverage" => "complete", "scope_revision" => "scope-v1",
      "planning_hold" => {
        "owner" => "paid", "task_kind" => "implementation", "operator_override" => false,
        "reason" => "Awaiting scoped readiness.", "release_condition" => "Scoped readiness passes.",
        "provenance" => { "source" => "publish_held_issue" }
      },
      "prerequisites" => [ { "id" => "scope", "assessment" => { "status" => "completed", "evidence_revision" => "e1", "intent_score" => 80, "technical_score" => 80 } } ],
      "design_artifacts" => [ { "path" => "docs/intent/example.md", "required" => true, "merged" => true, "scope_revision" => "scope-v1", "revision" => "a" * 40 } ]
    }
  end
  let!(:link) { create(:feature_intent_issue, feature_intent: feature, issue: issue, readiness_mapping: mapping) }

  before do
    allow(project.client).to receive(:remove_label_from_issue)
  end

  it "releases only Paid's planning hold and snapshots the passing baseline" do
    result = described_class.call(issue: issue)

    expect(result).to be_released
    expect(project.client).to have_received(:remove_label_from_issue).with(project.full_name, issue.github_number, "planning")
    expect(link.reload).to have_attributes(release_state: "released", release_error: nil)
    expect(link.release_snapshot).to include("scope_revision" => "scope-v1", "delivery_policy" => "confidence_driven")
    expect(issue.reload.labels).to contain_exactly("human-hold")
  end

  it "uses the persisted prerequisite mapping when the compatibility payload is empty" do # @spec CONFIDENCE-DELIVERY-003
    link.update!(readiness_mapping: mapping.slice("planning_hold"))
    persisted_mapping = create(:feature_intent_issue_prerequisite_mapping,
      feature_intent_issue: link,
      relevant_design_documents: mapping.fetch("design_artifacts"))
    facet = create(:feature_intent_facet, feature_intent: feature)
    direction = create(:feature_intent_facet_direction, feature_intent_facet: facet)
    create(:feature_intent_facet_assessment,
      feature_intent_facet_direction: direction,
      evidence_revision: facet.evidence_revision,
      status: "completed",
      intent_score: 80,
      technical_score: 80)
    create(:feature_intent_issue_prerequisite,
      feature_intent_issue_prerequisite_mapping: persisted_mapping,
      feature_intent_facet: facet,
      feature_intent_facet_direction: direction)
    persisted_mapping.update!(coverage_assessment: "complete")

    result = described_class.call(issue: issue)

    expect(result).to be_released
    expect(link.reload.release_snapshot).to include("scope_revision" => "scope-v1")
  end

  it "keeps an unassessed issue held without calling GitHub" do
    link.update!(readiness_mapping: mapping.slice("planning_hold"))

    expect(described_class.call(issue: issue)).not_to be_released
    expect(project.client).not_to have_received(:remove_label_from_issue)
    expect(link.reload.release_state).to eq("held")
  end

  it "keeps a ready-mapped issue held while a local dependency remains open" do # @spec CONFIDENCE-DELIVERY-003
    dependency = create(:issue, project: project, github_state: "open")
    create(:issue_dependency, issue: issue, depends_on_issue: dependency)

    result = described_class.call(issue: issue)

    expect(result).not_to be_released
    expect(result.reason).to eq("Issue has unresolved dependencies.")
    expect(project.client).not_to have_received(:remove_label_from_issue)
    expect(link.reload).to have_attributes(
      release_state: "held",
      release_error: "Issue has unresolved dependencies."
    )
    expect(issue.reload.labels).to contain_exactly("planning", "human-hold")
  end

  it "retains a visible retry state when GitHub rejects the planning-label removal" do
    allow(project.client).to receive(:remove_label_from_issue).and_raise(GithubClient::ApiError, "unavailable")

    result = described_class.call(issue: issue)

    expect(result).not_to be_released
    expect(link.reload).to have_attributes(release_state: "reconciliation_failed", release_error: "unavailable")
    expect(issue.reload.labels).to include("planning")
  end

  it "releases when the remote planning hold was already removed" do
    allow(project.client).to receive(:remove_label_from_issue).and_raise(GithubClient::NotFoundError, "Label not found")

    result = described_class.call(issue: issue)

    expect(result).to be_released
    expect(link.reload).to have_attributes(release_state: "released", release_error: nil)
    expect(issue.reload.labels).to contain_exactly("human-hold")
  end

  it "does not release stale scope when it changes during the GitHub reconciliation" do
    allow(project.client).to receive(:remove_label_from_issue) do
      link.update!(readiness_mapping: mapping.merge("scope_revision" => "scope-v2"))
    end

    result = described_class.call(issue: issue)

    expect(result).not_to be_released
    expect(link.reload.release_state).to eq("pending")
  end

  it "releases every confidence link the issue serves with one planning-hold removal" do
    second_feature = create(:feature_intent, :confidence_driven, project: project)
    second_link = create(:feature_intent_issue, feature_intent: second_feature, issue: issue, readiness_mapping: mapping)

    result = described_class.call(issue: issue)

    expect(result).to be_released
    expect(project.client).to have_received(:remove_label_from_issue).once
      .with(project.full_name, issue.github_number, "planning")
    expect(link.reload).to have_attributes(release_state: "released")
    expect(second_link.reload).to have_attributes(release_state: "released", release_error: nil)
    expect(second_link.release_snapshot).to include("scope_revision" => "scope-v1", "issue_id" => issue.id)
    expect(issue.reload.labels).to contain_exactly("human-hold")
  end

  it "keeps the issue held when any design the issue serves is not ready" do
    second_feature = create(:feature_intent, :confidence_driven, project: project)
    second_link = create(:feature_intent_issue, feature_intent: second_feature, issue: issue, readiness_mapping: {})

    result = described_class.call(issue: issue)

    expect(result).not_to be_released
    expect(result.reason).to include("coverage has not been confirmed")
    expect(project.client).not_to have_received(:remove_label_from_issue)
    expect(second_link.reload).to have_attributes(release_state: "held")
    expect(second_link.release_error).to include("coverage has not been confirmed")
    expect(link.reload).to have_attributes(release_state: "held", release_error: nil)
    expect(issue.reload.labels).to contain_exactly("planning", "human-hold")
  end

  it "records each blocked design's own blockers when several are not ready" do
    link.update!(readiness_mapping: mapping.slice("planning_hold"))
    second_feature = create(:feature_intent, :confidence_driven, project: project)
    second_link = create(:feature_intent_issue, feature_intent: second_feature, issue: issue, readiness_mapping: {})

    result = described_class.call(issue: issue)

    expect(result).not_to be_released
    expect(link.reload.release_error).to include("coverage has not been confirmed")
    expect(second_link.reload.release_error).to include("coverage has not been confirmed")
  end

  it "leaves an already-released link's immutable snapshot alone when a later design reconciles" do
    link.update!(release_state: "released", released_at: Time.current, release_snapshot: { "scope_revision" => "scope-v1", "preserved" => true })
    second_feature = create(:feature_intent, :confidence_driven, project: project)
    create(:feature_intent_issue, feature_intent: second_feature, issue: issue, readiness_mapping: mapping)

    result = described_class.call(issue: issue)

    expect(result).to be_released
    expect(link.reload.release_snapshot).to include("preserved" => true)
  end

  # @spec CONFIDENCE-DELIVERY-006
  it "removes an externally re-added planning label when every design already released without a hold receipt" do # @spec CONFIDENCE-DELIVERY-006, CONFIDENCE-DELIVERY-017
    link.update!(
      readiness_mapping: mapping.except("planning_hold"),
      release_state: "released",
      released_at: Time.current,
      release_snapshot: { "scope_revision" => "scope-v1", "preserved" => true }
    )

    result = described_class.call(issue: issue)

    expect(result).to be_released
    expect(project.client).to have_received(:remove_label_from_issue).with(project.full_name, issue.github_number, "planning")
    expect(link.reload).to have_attributes(release_state: "released", release_error: nil)
    expect(link.release_snapshot).to include("preserved" => true)
    expect(issue.reload.labels).to contain_exactly("human-hold")
  end

  it "does not call GitHub for a fully released issue whose planning label is absent" do
    link.update!(release_state: "released", released_at: Time.current)
    issue.update!(labels: [ "human-hold" ])

    result = described_class.call(issue: issue)

    expect(result).to be_released
    expect(project.client).not_to have_received(:remove_label_from_issue)
  end

  it "leaves a human planning hold untouched when the issue serves no confidence design" do
    link.destroy!

    result = described_class.call(issue: issue)

    expect(result).to be_released
    expect(project.client).not_to have_received(:remove_label_from_issue)
    expect(issue.reload.labels).to contain_exactly("planning", "human-hold")
  end

  it "keeps a legacy planning label visible when no Paid-owned hold receipt exists" do # @spec CONFIDENCE-DELIVERY-017
    link.update!(readiness_mapping: mapping.except("planning_hold"))

    result = described_class.call(issue: issue)

    expect(result).not_to be_released
    expect(result.reason).to include("ownership")
    expect(project.client).not_to have_received(:remove_label_from_issue)
    expect(issue.reload.labels).to contain_exactly("planning", "human-hold")
  end

  it "reconciles an unlabelled planning task to the released candidate state" do # @spec CONFIDENCE-DELIVERY-017
    planning_issue = create(:issue, project: project, labels: [])
    planning_link = create(:feature_intent_issue,
      feature_intent: feature,
      issue: planning_issue,
      readiness_mapping: mapping.merge("planning_hold" => mapping.fetch("planning_hold").merge("task_kind" => "planning")))

    result = described_class.call(issue: planning_issue)

    expect(result).to be_released
    expect(planning_link.reload).to have_attributes(release_state: "released", release_error: nil)
    expect(planning_link.release_snapshot).to eq({})
    expect(project.client).not_to have_received(:remove_label_from_issue)
  end

  it "keeps a planning task held while an independent dependency is open" do # @spec CONFIDENCE-DELIVERY-017
    planning_issue = create(:issue, project: project, labels: [])
    create(:feature_intent_issue,
      feature_intent: feature,
      issue: planning_issue,
      readiness_mapping: mapping.merge("planning_hold" => mapping.fetch("planning_hold").merge("task_kind" => "planning")))
    dependency = create(:issue, project: project, github_state: "open")
    create(:issue_dependency, issue: planning_issue, depends_on_issue: dependency)

    result = described_class.call(issue: planning_issue)

    expect(result).not_to be_released
    expect(result.reason).to eq("Issue has unresolved dependencies.")
    expect(planning_issue.feature_intent_issues.first.reload.release_state).to eq("held")
  end

  it "preserves a planning-task operator hold shared with ready implementation work" do # @spec CONFIDENCE-DELIVERY-004, CONFIDENCE-DELIVERY-017
    planning_feature = create(:feature_intent, :confidence_driven, project: project)
    create(:feature_intent_issue,
      feature_intent: planning_feature,
      issue: issue,
      readiness_mapping: mapping.merge("planning_hold" => mapping.fetch("planning_hold").merge("task_kind" => "planning")))

    result = described_class.call(issue: issue)

    expect(result).not_to be_released
    expect(result.reason).to include("ownership")
    expect(project.client).not_to have_received(:remove_label_from_issue)
    expect(link.reload).to have_attributes(release_state: "held")
    expect(issue.reload.labels).to contain_exactly("planning", "human-hold")
  end

  it "does not sweep a shared planning-task hold after implementation work released" do # @spec CONFIDENCE-DELIVERY-004, CONFIDENCE-DELIVERY-017
    link.update!(release_state: "released", released_at: Time.current)
    planning_feature = create(:feature_intent, :confidence_driven, project: project)
    create(:feature_intent_issue,
      feature_intent: planning_feature,
      issue: issue,
      readiness_mapping: mapping.merge("planning_hold" => mapping.fetch("planning_hold").merge("task_kind" => "planning")))

    result = described_class.call(issue: issue)

    expect(result).to be_released
    expect(project.client).not_to have_received(:remove_label_from_issue)
    expect(issue.reload.labels).to contain_exactly("planning", "human-hold")
  end

  it "preserves an overridden planning-task hold shared with implementation work" do # @spec CONFIDENCE-DELIVERY-004, CONFIDENCE-DELIVERY-017
    planning_feature = create(:feature_intent, :confidence_driven, project: project)
    create(:feature_intent_issue,
      feature_intent: planning_feature,
      issue: issue,
      readiness_mapping: mapping.merge("planning_hold" => mapping.fetch("planning_hold").merge(
        "task_kind" => "planning", "operator_override" => true
      )))

    result = described_class.call(issue: issue)

    expect(result).not_to be_released
    expect(project.client).not_to have_received(:remove_label_from_issue)
    expect(issue.reload.labels).to contain_exactly("planning", "human-hold")
  end

  it "reports a failed projection reconciliation without touching released evidence" do
    link.update!(release_state: "released", released_at: Time.current, release_snapshot: { "scope_revision" => "scope-v1", "preserved" => true })
    allow(project.client).to receive(:remove_label_from_issue).and_raise(GithubClient::ApiError, "unavailable")

    result = described_class.call(issue: issue)

    expect(result).not_to be_released
    expect(result.reason).to include("unavailable")
    expect(link.reload).to have_attributes(release_state: "released", release_error: nil)
    expect(link.release_snapshot).to include("preserved" => true)
    expect(issue.reload.labels).to include("planning")
  end
end
