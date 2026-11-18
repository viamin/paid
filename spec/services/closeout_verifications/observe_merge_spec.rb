# frozen_string_literal: true

require "rails_helper"

RSpec.describe CloseoutVerifications::ObserveMerge do
  let(:project) { create(:project) }
  let(:owner) { create(:user, :owner, account: project.account) }
  let(:source_issue) { create(:issue, project:) }
  let(:source_pr) { create(:issue, :pull_request, project:, parent_issue: source_issue, pr_review_phase: "ready") }
  let(:merge_sha) { "a" * 40 }

  before do
    FeatureFlags.enable!(:automation_phases, project:)
    project.update!(automation_phase_settings: { "phases" => { "release_deployment" => true } })
    StagedCloseoutAdoption::Enroll.call(project:, actor: owner, enabled: true)
    source_pr
    create(:agent_run, :completed, project:, issue: source_issue, reconciliation: { "assessment" => {
      "source_revision" => PartialCloseouts::Assessment.source_revision_for(source_issue),
      "intent_revision" => PartialCloseouts::Assessment.intent_revision_for(source_issue),
      "criteria" => [ { "criterion" => "Merged evidence", "state" => "unmet" } ], "gaps" => []
    } })
    recipe = create(:pre_commit_requirement, project:, account: project.account)
    StagedCloseoutAdoption::Mappings.approve(project:, actor: owner, issue: source_issue, attributes: {
      criterion_key: "Merged evidence", stage: "merged_revision", phase: "release_deployment",
      target_shape: "source_pr_merged_revision", execution_path: "technical_prerequisite",
      target_key: recipe.id, freshness_seconds: 60
    })
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-009 STAGED-CLOSEOUT-ADOPTION-010
  it "admits the reviewed criterion after a real open-to-merged transition changes delivery evidence" do
    source_pr.update!(github_state: "closed", pr_review_phase: "merged")
    expect(PartialCloseouts::Assessment.call(source_issue)).to be_stale

    result = described_class.call(source_pr:, merge_commit_sha: merge_sha)

    expect(result).to be_admitted
    expect(result.runs.sole.base_commit_sha).to eq(merge_sha)
    expect(described_class.call(source_pr:, merge_commit_sha: merge_sha).reason).to eq("already_admitted")
    expect(PartialCloseouts::Assessment.call(source_issue)).to be_stale
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-010
  it "still refuses admission when source intent changes before the merge" do
    source_issue.update!(body: "Changed acceptance intent")
    source_pr.update!(github_state: "closed", pr_review_phase: "merged")

    expect(described_class.call(source_pr:, merge_commit_sha: merge_sha)).not_to be_admitted
    expect(AgentRun.where(goal: "closeout_verification")).to be_empty
  end
end
