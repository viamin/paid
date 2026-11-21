# frozen_string_literal: true

require "rails_helper"

RSpec.describe CloseoutVerifications::Execute do
  # @spec PARTIAL-CLOSEOUT-059
  let(:agent_run) do
    create(:agent_run, :queued, project:, issue:, agent_type: "internal_agent", goal: AgentRun::CLOSEOUT_VERIFICATION_GOAL,
      synthetic: true, source_pull_request_number: source_pr.github_number, base_commit_sha: source_pr.merged_commit_sha,
      closeout_mapping_id: mapping.id, closeout_criterion_key: mapping.criterion_key,
      closeout_recipe_version: mapping.target_version, closeout_recipe_digest: mapping.target_digest)
  end
  let(:mapping) { approve_mapping }
  let(:recipe) { create(:pre_commit_requirement, project:, account: project.account, enabled: true, command: "bin/fixture-check") }
  let(:source_pr) { create(:issue, :pull_request, project:, github_number: 42, pr_review_phase: "merged", merged_commit_sha: "a" * 40) }
  let(:issue) { create(:issue, project:) }
  let(:maintainer) { create(:user, :owner, account: project.account) }
  let(:project) { create(:project) }

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

  it "uses the limit bound into the reviewed staged target" do
    recipe.update!(native_timeout_seconds: 600)
    expect(TechnicalPrerequisites::ValidateExecution).to receive(:call)
      .with(agent_run:, native_command: recipe.command, native_timeout_seconds: 600)
      .and_return(validation_result("completed"))

    described_class.call(agent_run:)
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

  # @spec PARTIAL-CLOSEOUT-057
  it "requests exactly one report-only acceptance audit after a newly terminal passing result" do
    allow(TechnicalPrerequisites::ValidateExecution).to receive(:call)
      .and_return(validation_result("completed", { "native" => { "exit_code" => 0 }, "cleanup" => { "completed" => true } }))
    allow(PartialCloseouts::AutoAudit).to receive(:call).and_call_original

    described_class.call(agent_run:)

    expect(PartialCloseouts::AutoAudit).to have_received(:call).with(issue:).once
  end

  # @spec PARTIAL-CLOSEOUT-057
  it "requests a report-only audit after a newly terminal failing result" do
    allow(TechnicalPrerequisites::ValidateExecution).to receive(:call)
      .and_return(validation_result("failed", { "native" => { "exit_code" => 1 }, "cleanup" => { "completed" => true } }))
    allow(PartialCloseouts::AutoAudit).to receive(:call)

    described_class.call(agent_run:)

    expect(PartialCloseouts::AutoAudit).to have_received(:call).with(issue:).once
  end

  # @spec PARTIAL-CLOSEOUT-057
  it "does not request an audit when the result is cancelled before execution" do
    agent_run.cancel!
    allow(TechnicalPrerequisites::ValidateExecution).to receive(:call)
    allow(PartialCloseouts::AutoAudit).to receive(:call)

    described_class.call(agent_run:)

    expect(PartialCloseouts::AutoAudit).not_to have_received(:call)
  end

  # @spec PARTIAL-CLOSEOUT-057
  it "does not request an audit when claim refuses a stale mapping" do
    mapping.update_column(:target_digest, "changed")
    allow(TechnicalPrerequisites::ValidateExecution).to receive(:call)
    allow(PartialCloseouts::AutoAudit).to receive(:call)

    described_class.call(agent_run:)

    expect(agent_run.reload.verification_result.dig("closeout_verification", "outcome")).to eq("stale")
    expect(PartialCloseouts::AutoAudit).not_to have_received(:call)
  end

  # @spec PARTIAL-CLOSEOUT-057
  it "does not request a second audit on a replayed delivery against an already-terminal run" do
    agent_run.update!(status: "completed", completed_at: Time.current)
    allow(TechnicalPrerequisites::ValidateExecution).to receive(:call)
    allow(PartialCloseouts::AutoAudit).to receive(:call)

    described_class.call(agent_run:)

    expect(TechnicalPrerequisites::ValidateExecution).not_to have_received(:call)
    expect(PartialCloseouts::AutoAudit).not_to have_received(:call)
  end

  # @spec PARTIAL-CLOSEOUT-057
  it "requests an audit after an unhandled pre-execution exception records a terminal outcome" do
    allow(PartialCloseouts::AutoAudit).to receive(:call)

    described_class.record_exception!(agent_run:, error: ApplicationJob::PerformTimeoutError.new("timed out"))

    expect(agent_run.reload.verification_result.dig("closeout_verification", "outcome")).to eq("timeout")
    expect(PartialCloseouts::AutoAudit).to have_received(:call).with(issue:).once
  end

  # @spec PARTIAL-CLOSEOUT-057
  it "never schedules implementation (create_pr) continuation work as a side effect" do
    allow(TechnicalPrerequisites::ValidateExecution).to receive(:call)
      .and_return(validation_result("completed", { "native" => { "exit_code" => 0 }, "cleanup" => { "completed" => true } }))

    expect { described_class.call(agent_run:) }.not_to change { AgentRun.where(goal: "create_pr").count }
  end

  # @spec PARTIAL-CLOSEOUT-057
  it "does not request an audit when intent changes during verification" do
    allow(TechnicalPrerequisites::ValidateExecution).to receive(:call) do
      issue.update!(body: "Changed acceptance")
      validation_result("completed", { "native" => { "exit_code" => 0 } })
    end
    allow(PartialCloseouts::AutoAudit).to receive(:call)

    described_class.call(agent_run:)

    expect(PartialCloseouts::AutoAudit).not_to have_received(:call)
  end

  # @spec PARTIAL-CLOSEOUT-057
  it "does not request an audit when the authoritative target changes during verification" do
    allow(TechnicalPrerequisites::ValidateExecution).to receive(:call) do
      source_pr.update!(merged_commit_sha: "b" * 40)
      validation_result("completed", { "native" => { "exit_code" => 0 } })
    end
    allow(PartialCloseouts::AutoAudit).to receive(:call)

    described_class.call(agent_run:)

    expect(PartialCloseouts::AutoAudit).not_to have_received(:call)
  end

  %w[completed failed].each do |result_status|
    # @spec PARTIAL-CLOSEOUT-057
    it "admits one actual report-only audit after #{result_status} verification" do
      project.update!(auto_pick_enabled: true, created_by: maintainer)
      issue.update!(paid_state: "completed")
      source_pr.update!(parent_issue: issue, github_state: "closed")
      assessment_run = issue.agent_runs.sole
      assessment_run.update!(goal: "analyze_issue", pull_request_number: nil, pull_request_url: nil)
      assessment_run.update!(reconciliation: { "assessment" => {
        "source_revision" => PartialCloseouts::Assessment.source_revision_for(issue),
        "intent_revision" => PartialCloseouts::Assessment.intent_revision_for(issue),
        "criteria" => [ { "criterion" => "Merged evidence", "state" => "unmet" } ], "gaps" => []
      } })
      allow(TechnicalPrerequisites::ValidateExecution).to receive(:call).and_return(
        validation_result(result_status, { "native" => { "exit_code" => result_status == "completed" ? 0 : 1 } }))

      described_class.call(agent_run:)
      2.times { PartialCloseouts::AutoAudit.call(issue:) }

      audits = IssueContinuationRequest.where(issue:).where("evidence->>'continuation_mode' = ?", "acceptance_audit")
      expect(audits.count).to eq(1)
      expect(audits.sole.evidence.fetch("source_revision")).to eq(PartialCloseouts::Assessment.source_revision_for(issue))
      expect(AgentRun.find_by!(continuation_request_id: audits.sole.id).goal).to eq("analyze_issue")
      expect(issue.agent_runs.where(goal: "create_pr")).to be_empty
    end
  end
end
