# frozen_string_literal: true

require "rails_helper"

RSpec.describe CloseoutVerificationJob do
  let(:project) { create(:project) }
  let(:maintainer) { create(:user, :owner, account: project.account) }
  let(:issue) { create(:issue, project:) }
  let(:source_pr) { create(:issue, :pull_request, project:, github_number: 42, pr_review_phase: "merged", merged_commit_sha: "a" * 40) }
  let(:recipe) { create(:pre_commit_requirement, project:, account: project.account, enabled: true, command: "bin/fixture-check") }
  let(:mapping) { approve_mapping }
  let(:agent_run) do
    create(:agent_run, :queued, project:, issue:, agent_type: "internal_agent", goal: AgentRun::CLOSEOUT_VERIFICATION_GOAL,
      synthetic: true, source_pull_request_number: source_pr.github_number, base_commit_sha: source_pr.merged_commit_sha,
      closeout_mapping_id: mapping.id, closeout_criterion_key: mapping.criterion_key,
      closeout_recipe_version: mapping.target_version, closeout_recipe_digest: mapping.target_digest)
  end

  before do
    FeatureFlags.enable!(:automation_phases, project:)
    project.update!(automation_phase_settings: { "phases" => { "release_deployment" => true } })
    StagedCloseoutAdoption::Enroll.call(project:, actor: maintainer, enabled: true)
    create(:agent_run, :completed, project:, issue:, reconciliation: { "assessment" => {
      "source_revision" => PartialCloseouts::Assessment.source_revision_for(issue),
      "intent_revision" => PartialCloseouts::Assessment.intent_revision_for(issue),
      "criteria" => [ { "criterion" => "Merged evidence", "state" => "unmet" } ], "gaps" => []
    } })
  end

  def approve_mapping
    StagedCloseoutAdoption::Mappings.approve(project:, actor: maintainer, issue:, attributes: {
      criterion_key: "Merged evidence", stage: "merged_revision", phase: "release_deployment",
      target_shape: "source_pr_merged_revision", execution_path: "technical_prerequisite",
      target_key: recipe.id, freshness_seconds: 60
    })
  end

  def validation_result(status, evidence = {})
    TechnicalPrerequisites::ValidateExecution::Result.new(status:, evidence:, setup_action: nil)
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-011
  it "executes the current reviewed fixture recipe at the recorded merged commit and records inspectable evidence" do
    allow(TechnicalPrerequisites::ValidateExecution).to receive(:call)
      .and_return(validation_result("completed", { "checkout" => "a" * 40, "native" => { "exit_code" => 0 }, "cleanup" => { "completed" => true } }))

    described_class.perform_now(agent_run.id)

    expect(TechnicalPrerequisites::ValidateExecution).to have_received(:call).with(agent_run:, native_command: "bin/fixture-check")
    expect(agent_run.reload).to have_attributes(status: "completed", base_commit_sha: "a" * 40)
    expect(agent_run.verification_result.fetch("closeout_verification")).to include(
      "outcome" => "passed", "source_issue_id" => issue.id, "criterion" => "Merged evidence",
      "source_pr_number" => 42, "merged_commit_sha" => "a" * 40,
      "recipe_version" => mapping.target_version, "recipe_digest" => mapping.target_digest,
      "command" => "bin/fixture-check"
    )
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-011
  it "refuses a changed reviewed recipe before repository execution" do
    mapping.update_column(:target_digest, "changed")
    allow(TechnicalPrerequisites::ValidateExecution).to receive(:call)

    described_class.perform_now(agent_run.id)

    expect(TechnicalPrerequisites::ValidateExecution).not_to have_received(:call)
    expect(agent_run.reload.verification_result.dig("closeout_verification", "outcome")).to eq("stale")
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-011
  it "rechecks automatic release authorization before repository execution" do
    project.update!(automation_phase_settings: { "phases" => { "release_deployment" => false } })
    allow(TechnicalPrerequisites::ValidateExecution).to receive(:call)

    described_class.perform_now(agent_run.id)

    expect(TechnicalPrerequisites::ValidateExecution).not_to have_received(:call)
    expect(agent_run.reload.verification_result.dig("closeout_verification", "error"))
      .to eq("automatic release policy is no longer permitted")
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-011
  it "records a failed fixture test without turning its partial output into a pass" do
    allow(TechnicalPrerequisites::ValidateExecution).to receive(:call)
      .and_return(validation_result("failed", { "native" => { "exit_code" => 1 }, "cleanup" => { "completed" => true } }))

    described_class.perform_now(agent_run.id)

    expect(agent_run.reload.verification_result.dig("closeout_verification", "outcome")).to eq("failed")
    expect(agent_run.status).to eq("failed")
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-011
  it "preserves unavailable tooling as an unavailable outcome" do
    allow(TechnicalPrerequisites::ValidateExecution).to receive(:call)
      .and_return(validation_result("unavailable", { "setup_action" => "Restore fixture tool", "cleanup" => { "attempted" => false } }))

    described_class.perform_now(agent_run.id)

    expect(agent_run.reload.verification_result.dig("closeout_verification", "outcome")).to eq("unavailable")
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-011
  it "does not replay a terminal attempt" do
    agent_run.update!(status: "completed", completed_at: Time.current)
    allow(TechnicalPrerequisites::ValidateExecution).to receive(:call)

    described_class.perform_now(agent_run.id)

    expect(TechnicalPrerequisites::ValidateExecution).not_to have_received(:call)
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-011
  it "records timeout and cleanup failures as actionable non-passes" do
    allow(TechnicalPrerequisites::ValidateExecution).to receive(:call)
      .and_raise(ApplicationJob::PerformTimeoutError, "fixture timed out")

    expect { described_class.perform_now(agent_run.id) }.to raise_error(ApplicationJob::PerformTimeoutError)
    expect(agent_run.reload.verification_result.dig("closeout_verification", "outcome")).to eq("timeout")

    second_pr = create(:issue, :pull_request, project:, github_number: 43, pr_review_phase: "merged", merged_commit_sha: "b" * 40)
    retry_run = create(:agent_run, :queued, project:, issue:, agent_type: "internal_agent", goal: AgentRun::CLOSEOUT_VERIFICATION_GOAL,
      synthetic: true, source_pull_request_number: second_pr.github_number, base_commit_sha: second_pr.merged_commit_sha,
      closeout_mapping_id: mapping.id, closeout_criterion_key: mapping.criterion_key,
      closeout_recipe_version: mapping.target_version, closeout_recipe_digest: mapping.target_digest)
    allow(TechnicalPrerequisites::ValidateExecution).to receive(:call)
      .and_return(validation_result("completed", { "cleanup" => { "completed" => false, "errors" => [ { "message" => "cleanup failed" } ] } }))

    described_class.perform_now(retry_run.id)

    expect(retry_run.reload.verification_result.dig("closeout_verification", "outcome")).to eq("cleanup_failed")
  end
end
