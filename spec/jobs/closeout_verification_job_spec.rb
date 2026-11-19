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
  it "executes in the admitted run's tenant context" do
    observed_account = nil
    allow(TechnicalPrerequisites::ValidateExecution).to receive(:call) do
      observed_account = Current.account
      validation_result("completed", { "cleanup" => { "completed" => true } })
    end

    described_class.perform_now(agent_run.id)

    expect(observed_account).to eq(project.account)
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
  it "defers a paused project without consuming the admitted identity" do
    project.pause!
    allow(TechnicalPrerequisites::ValidateExecution).to receive(:call)

    described_class.perform_now(agent_run.id)

    expect(TechnicalPrerequisites::ValidateExecution).not_to have_received(:call)
    expect(agent_run.reload).to have_attributes(status: "queued", started_at: nil, completed_at: nil)
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-016
  it "defers a paused source issue without executing the native recipe" do
    run = agent_run
    stub_request(:post, "https://api.github.com/repos/#{project.full_name}/issues/#{issue.github_number}/labels")
      .to_return(status: 200, body: "[]")
    issue.update!(paused: true)
    allow(TechnicalPrerequisites::ValidateExecution).to receive(:call)
      .and_return(validation_result("completed", { "native" => { "exit_code" => 0 }, "cleanup" => { "completed" => true } }))

    described_class.perform_now(run.id)

    expect(TechnicalPrerequisites::ValidateExecution).not_to have_received(:call)
    expect(run.reload).to have_attributes(status: "queued", started_at: nil, completed_at: nil)
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-011
  it "defers a hard-stop budget without consuming the admitted identity" do
    allow(CostBudgets::Check).to receive(:call).and_return({ allowed: false, reason: "hard stop" })
    allow(TechnicalPrerequisites::ValidateExecution).to receive(:call)

    described_class.perform_now(agent_run.id)

    expect(TechnicalPrerequisites::ValidateExecution).not_to have_received(:call)
    expect(agent_run.reload).to have_attributes(status: "queued", started_at: nil, completed_at: nil)
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-011
  it "defers an assessment that became stale after admission" do
    mapping
    issue.update!(body: "Changed intent")
    allow(TechnicalPrerequisites::ValidateExecution).to receive(:call)

    described_class.perform_now(agent_run.id)

    expect(TechnicalPrerequisites::ValidateExecution).not_to have_received(:call)
    expect(agent_run.reload).to have_attributes(status: "queued", started_at: nil, completed_at: nil)
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
  it "preserves a returned technical setup error as a setup failure" do
    allow(TechnicalPrerequisites::ValidateExecution).to receive(:call)
      .and_return(validation_result("failed", { "error" => "fixture provisioning failed", "checkout" => nil,
        "cleanup" => { "attempted" => true } }))

    described_class.perform_now(agent_run.id)

    expect(agent_run.reload).to have_attributes(status: "failed", error_message: "fixture provisioning failed")
    expect(agent_run.verification_result.dig("closeout_verification", "outcome")).to eq("setup_failed")
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-011
  it "preserves unavailable tooling as an unavailable outcome" do
    allow(TechnicalPrerequisites::ValidateExecution).to receive(:call)
      .and_return(validation_result("unavailable", { "setup_action" => "Restore fixture tool", "cleanup" => { "attempted" => false } }))

    described_class.perform_now(agent_run.id)

    expect(agent_run.reload.verification_result.dig("closeout_verification", "outcome")).to eq("unavailable")
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-011
  it "records closeout evidence when a queued verification is cancelled before execution" do
    agent_run.cancel!
    allow(TechnicalPrerequisites::ValidateExecution).to receive(:call)

    described_class.perform_now(agent_run.id)

    expect(TechnicalPrerequisites::ValidateExecution).not_to have_received(:call)
    expect(agent_run.reload).to have_attributes(status: "cancelled", completed_at: be_present)
    expect(agent_run.verification_result.dig("closeout_verification", "outcome")).to eq("cancelled")
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-011
  it "records closeout evidence when cancellation occurs during execution" do
    allow(TechnicalPrerequisites::ValidateExecution).to receive(:call) do
      agent_run.cancel!
      validation_result("cancelled", { "cleanup" => { "attempted" => true } })
    end

    described_class.perform_now(agent_run.id)

    expect(agent_run.reload).to have_attributes(status: "cancelled", completed_at: be_present)
    expect(agent_run.verification_result.dig("closeout_verification", "outcome")).to eq("cancelled")
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-011
  it "does not replay a terminal attempt" do
    agent_run.update!(status: "completed", completed_at: Time.current)
    allow(TechnicalPrerequisites::ValidateExecution).to receive(:call)

    described_class.perform_now(agent_run.id)

    expect(TechnicalPrerequisites::ValidateExecution).not_to have_received(:call)
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-011
  it "does not reclaim a run that a duplicate delivery is already executing" do
    started_at = 2.minutes.ago
    agent_run.update!(status: "running", started_at:)
    allow(TechnicalPrerequisites::ValidateExecution).to receive(:call)

    described_class.perform_now(agent_run.id)

    expect(TechnicalPrerequisites::ValidateExecution).not_to have_received(:call)
    expect(agent_run.reload).to have_attributes(status: "running",
      started_at: be_within(1.second).of(started_at), completed_at: nil)
    expect(agent_run.verification_result).not_to include("closeout_verification")
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

  # @spec STAGED-CLOSEOUT-ADOPTION-011
  it "leaves a transient pre-execution exception queued for a later delivery" do
    allow(CostBudgets::Check).to receive(:call)
      .and_raise(ActiveRecord::StatementInvalid, "temporary database failure")

    expect { described_class.perform_now(agent_run.id) }.to raise_error(ActiveRecord::StatementInvalid)

    expect(agent_run.reload).to have_attributes(status: "queued", completed_at: nil)
    expect(agent_run.verification_result).not_to include("closeout_verification")
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-011
  it "records a cleanup failure when only the persisted technical record carries the verdict" do
    # The real executor builds its Result before cleanup runs, so the returned
    # evidence only records that cleanup was attempted; the verdict is written
    # to the run's persisted technical record by the cleanup path afterwards.
    allow(TechnicalPrerequisites::ValidateExecution).to receive(:call) do
      agent_run.update!(verification_result: agent_run.verification_result.merge(
        TechnicalPrerequisites::EVIDENCE_KEY => {
          "status" => "completed", "cleanup" => { "attempted" => true, "completed" => false,
            "errors" => [ { "class" => "Containers::Provision::Error", "message" => "fixture cleanup failed" } ] }
        }
      ))
      validation_result("completed", { "native" => { "exit_code" => 0 }, "cleanup" => { "attempted" => true } })
    end

    described_class.perform_now(agent_run.id)

    expect(agent_run.reload).to have_attributes(status: "failed")
    expect(agent_run.verification_result.dig("closeout_verification", "outcome")).to eq("cleanup_failed")
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-011
  it "copies the durable runtime identity and final cleanup verdict into the closeout receipt" do
    allow(TechnicalPrerequisites::ValidateExecution).to receive(:call) do
      returned = { "environment" => { "container_id" => "fixture-container", "container_host" => "local" },
        "native" => { "exit_code" => 0 }, "cleanup" => { "attempted" => true } }
      agent_run.update!(container_id: nil, container_host: nil, verification_result: {
        TechnicalPrerequisites::EVIDENCE_KEY => returned.merge("cleanup" => { "attempted" => true, "completed" => true })
      })
      validation_result("completed", returned)
    end

    described_class.perform_now(agent_run.id)

    receipt = agent_run.reload.verification_result.fetch("closeout_verification")
    expect(receipt.fetch("environment")).to include("container_id" => "fixture-container", "container_host" => "local")
    expect(receipt.dig("technical_evidence", "cleanup", "completed")).to be(true)
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-011
  it "cancelled receipt retains the final persisted cleanup verdict" do
    allow(TechnicalPrerequisites::ValidateExecution).to receive(:call) do
      agent_run.cancel!
      agent_run.update!(verification_result: { TechnicalPrerequisites::EVIDENCE_KEY => {
        "environment" => { "container_id" => "fixture", "container_host" => "local" },
        "cleanup" => { "attempted" => true, "completed" => true }
      } })
      validation_result("cancelled", { "cleanup" => { "attempted" => true } })
    end
    described_class.perform_now(agent_run.id)
    expect(agent_run.reload.verification_result.dig("closeout_verification", "technical_evidence", "cleanup", "completed")).to be(true)
  end
end
