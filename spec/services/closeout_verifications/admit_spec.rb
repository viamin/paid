# frozen_string_literal: true

require "rails_helper"

RSpec.describe CloseoutVerifications::Admit do
  let(:project) { create(:project) }
  let(:maintainer) { create(:user, :owner, account: project.account) }
  let(:source_issue) { create(:issue, project:) }
  let(:source_pr) { create(:issue, :pull_request, project:, github_number: 42, pr_review_phase: "merged") }
  let!(:recipe) { create(:pre_commit_requirement, project:, account: project.account, enabled: true) }
  let(:merge_sha) { "a" * 40 }

  before do
    FeatureFlags.enable!(:automation_phases, project:)
    project.update!(automation_phase_settings: { "phases" => { "release_deployment" => true } })
    StagedCloseoutAdoption::Enroll.call(project:, actor: maintainer, enabled: true)
    create(:agent_run, :completed, project:, issue: source_issue, reconciliation: { "assessment" => {
      "source_revision" => PartialCloseouts::Assessment.source_revision_for(source_issue),
      "intent_revision" => PartialCloseouts::Assessment.intent_revision_for(source_issue),
      "criteria" => [ { "criterion" => "Merged evidence", "state" => "unmet" } ], "gaps" => []
    } })
    create(:agent_run, :completed, project:, issue: source_issue, pull_request_number: source_pr.github_number,
      result_commit_sha: "b" * 40)
  end

  def approve_mapping(stage: "merged_revision", **overrides)
    StagedCloseoutAdoption::Mappings.approve(project:, actor: maintainer, issue: source_issue, attributes: {
      criterion_key: "Merged evidence", stage:, phase: "release_deployment",
      target_shape: StagedCloseoutAdoption::Mappings::TARGET_SHAPES.fetch(stage),
      execution_path: "technical_prerequisite", target_key: recipe.id, freshness_seconds: 60
    }.merge(overrides))
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-009 STAGED-CLOSEOUT-ADOPTION-010
  it "admits exactly one non-triggerable synthetic run pinned to the observed merge" do
    mapping = approve_mapping

    outcome = described_class.call(source_pr:, merge_commit_sha: merge_sha)
    run = outcome.runs.fetch(0)

    expect(outcome).to be_admitted
    expect(run).to have_attributes(goal: "closeout_verification", status: "queued", synthetic: true,
      issue: source_issue, source_pull_request_number: 42, base_commit_sha: merge_sha,
      branch_name: a_string_matching(/\Acloseout-verification-[0-9a-f]{12}\z/),
      closeout_mapping_id: mapping.id, closeout_criterion_key: "Merged evidence",
      closeout_recipe_version: mapping.target_version, closeout_recipe_digest: mapping.target_digest)
    expect(AgentRun::TRIGGERABLE_GOALS).not_to include("closeout_verification")
    expect { described_class.call(source_pr:, merge_commit_sha: merge_sha) }
      .not_to change { AgentRun.where(goal: "closeout_verification").count }
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-009
  it "admits one run for every eligible mapping for the same issue and pull request" do
    assessment_run = AgentRun.completed.where(project:, issue: source_issue).find_by!(source_pull_request_number: nil)
    assessment = assessment_run.reconciliation.fetch("assessment")
    assessment["criteria"] << { "criterion" => "Second merged check", "state" => "unmet" }
    assessment_run.update!(reconciliation: { "assessment" => assessment })
    mappings = [ approve_mapping, approve_mapping(criterion_key: "Second merged check") ]

    outcome = described_class.call(source_pr:, merge_commit_sha: merge_sha)

    expect(outcome.runs.map(&:closeout_mapping_id)).to match_array(mappings.map(&:id))
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-009 STAGED-CLOSEOUT-ADOPTION-010
  it "admits a follow-up merged pull request while an earlier verification remains queued" do
    mapping = approve_mapping
    described_class.call(source_pr:, merge_commit_sha: merge_sha)
    follow_up_pr = create(:issue, :pull_request, project:, github_number: 43, pr_review_phase: "merged")
    create(:agent_run, :completed, project:, issue: source_issue,
      pull_request_number: follow_up_pr.github_number, result_commit_sha: "c" * 40)

    outcome = described_class.call(source_pr: follow_up_pr, merge_commit_sha: "d" * 40)

    expect(outcome.runs).to contain_exactly(an_object_having_attributes(
      closeout_mapping_id: mapping.id, source_pull_request_number: 43, base_commit_sha: "d" * 40
    ))
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-010
  it "converges concurrent admission and preserves a current completed result" do
    approve_mapping
    first = described_class.call(source_pr:, merge_commit_sha: merge_sha)
    replay = described_class.call(source_pr:, merge_commit_sha: merge_sha)
    run = AgentRun.find_by!(goal: "closeout_verification")
    run.update!(status: "completed", completed_at: Time.current)

    expect(first).to be_admitted
    expect(replay.reason).to eq("already_admitted")
    expect(described_class.call(source_pr:, merge_commit_sha: merge_sha).reason).to eq("already_current_result")
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-010
  it "converges an insert race on the database identity" do
    mapping = approve_mapping
    allow(AgentRun).to receive(:create!).and_wrap_original do |original, attributes|
      original.call(attributes)
      raise ActiveRecord::RecordNotUnique
    end

    outcome = described_class.call(source_pr:, merge_commit_sha: merge_sha)

    expect(outcome).not_to be_admitted
    expect(outcome.reason).to eq("already_admitted")
    expect(AgentRun.where(closeout_mapping_id: mapping.id)).to contain_exactly(an_object_having_attributes(status: "queued"))
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-010
  it "raises a uniqueness collision that does not match the admission identity" do
    approve_mapping
    allow(AgentRun).to receive(:create!).and_raise(ActiveRecord::RecordNotUnique)

    expect { described_class.call(source_pr:, merge_commit_sha: merge_sha) }
      .to raise_error(ActiveRecord::RecordNotUnique)
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-010
  it "returns inspectable no-run reasons for paused authority, changed intent, and live targets" do
    approve_mapping
    project.pause!
    expect(described_class.call(source_pr:, merge_commit_sha: merge_sha).reason).to eq("project_paused")

    project.unpause!
    source_issue.update!(body: "Changed intent")
    expect(described_class.call(source_pr:, merge_commit_sha: merge_sha).reason).to eq("closeout assessment is stale")
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-010
  it "does not treat a merge as a live-environment confirmation" do
    enrollment = project.staged_closeout_enrollment
    StagedCloseoutMapping.create!(account: project.account, project:, issue: source_issue,
      staged_closeout_enrollment: enrollment, reviewed_by: maintainer, criterion_key: "Merged evidence",
      criterion_digest: "criterion", stage: "live_environment", phase: "operations", target_shape: "live_signal",
      execution_path: "trusted_measurement", target_key: "digest_fixture", target_version: "1", target_digest: "digest",
      environment_class: "production", freshness_seconds: 60, revision: 1, reviewed_at: Time.current)

    expect(described_class.call(source_pr:, merge_commit_sha: merge_sha).reason).to eq("live_target_unconfirmed")
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-010
  it "preserves a merged-revision eligibility failure when a live mapping also exists" do
    approve_mapping
    source_issue.update!(body: "Changed intent")
    enrollment = project.staged_closeout_enrollment
    StagedCloseoutMapping.create!(account: project.account, project:, issue: source_issue,
      staged_closeout_enrollment: enrollment, reviewed_by: maintainer, criterion_key: "Live evidence",
      criterion_digest: "criterion", stage: "live_environment", phase: "operations", target_shape: "live_signal",
      execution_path: "trusted_measurement", target_key: "digest_fixture", target_version: "1", target_digest: "digest",
      environment_class: "production", freshness_seconds: 60, revision: 1, reviewed_at: Time.current)

    expect(described_class.call(source_pr:, merge_commit_sha: merge_sha).reason).to eq("closeout assessment is stale")
  end
end
