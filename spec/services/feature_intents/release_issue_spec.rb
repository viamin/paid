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

  it "keeps an unassessed issue held without calling GitHub" do
    link.update!(readiness_mapping: {})

    expect(described_class.call(issue: issue)).not_to be_released
    expect(project.client).not_to have_received(:remove_label_from_issue)
    expect(link.reload.release_state).to eq("held")
  end

  it "retains a visible retry state when GitHub rejects the planning-label removal" do
    allow(project.client).to receive(:remove_label_from_issue).and_raise(GithubClient::ApiError, "unavailable")

    result = described_class.call(issue: issue)

    expect(result).not_to be_released
    expect(link.reload).to have_attributes(release_state: "reconciliation_failed", release_error: "unavailable")
    expect(issue.reload.labels).to include("planning")
  end

  it "does not release stale scope when it changes during the GitHub reconciliation" do
    allow(project.client).to receive(:remove_label_from_issue) do
      link.update!(readiness_mapping: mapping.merge("scope_revision" => "scope-v2"))
    end

    result = described_class.call(issue: issue)

    expect(result).not_to be_released
    expect(link.reload.release_state).to eq("pending")
  end
end
