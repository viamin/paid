# frozen_string_literal: true

require "rails_helper"

RSpec.describe TechnicalPrerequisites::StartValidation do
  # @spec PARTIAL-CLOSEOUT-030
  it "queues a fresh pinned run from an enabled reviewed recipe" do
    project = create(:project)
    actor = project.created_by
    source_run = create(:agent_run, :completed, project:, base_commit_sha: "a" * 40)
    requirement = create(:pre_commit_requirement, project:, account: project.account, command: "bin/audit --quick")

    result = described_class.call(source_run:, requirement:, actor:)

    expect(result).to be_success
    expect(result.agent_run).to have_attributes(
      synthetic: true, status: "queued", base_commit_sha: "a" * 40,
      goal: "technical_prerequisite_validation"
    )
    expect(result.agent_run.external_metadata.dig("technical_prerequisite_validation", "command"))
      .to eq("bin/audit --quick")
    expect(TechnicalPrerequisiteValidationJob).to have_been_enqueued.with(result.agent_run.id)
  end

  # @spec PARTIAL-CLOSEOUT-030
  it "queues the validation for an issue whose feature intent is not released" do
    project = create(:project)
    actor = project.created_by
    issue = create(:issue, project:)
    feature = create(:feature_intent, project:, status: "approved_waiting_for_merge")
    create(:feature_intent_issue, feature_intent: feature, issue:)
    source_run = create(:agent_run, :completed, project:, issue:, goal: "enhance_issue", base_commit_sha: "a" * 40)
    requirement = create(:pre_commit_requirement, project:, account: project.account)

    result = described_class.call(source_run:, requirement:, actor:)

    expect(result).to be_success
    expect(result.agent_run.base_commit_sha).to eq("a" * 40)
  end

  # @spec PARTIAL-CLOSEOUT-030
  it "refuses a disabled recipe" do
    project = create(:project)
    source_run = create(:agent_run, :completed, project:, base_commit_sha: "a" * 40)
    requirement = create(:pre_commit_requirement, project:, account: project.account, enabled: false)

    result = described_class.call(source_run:, requirement:, actor: project.created_by)

    expect(result).not_to be_success
    expect(result.agent_run).to be_nil
  end

  # @spec PARTIAL-CLOSEOUT-030
  it "preserves reviewed recipe shell syntax for the isolated execution environment" do
    project = create(:project)
    source_run = create(:agent_run, :completed, project:, base_commit_sha: "a" * 40)
    command = "RAILS_ENV=test bundle exec rspec && echo done | tee validation.log"
    requirement = create(:pre_commit_requirement, project:, account: project.account, command:)

    result = described_class.call(source_run:, requirement:, actor: project.created_by)

    expect(result).to be_success
    expect(result.agent_run.external_metadata.dig("technical_prerequisite_validation", "command")).to eq(command)
  end

  # @spec PARTIAL-CLOSEOUT-030
  it "refuses a source run without a pinned checkout" do
    project = create(:project)
    source_run = create(:agent_run, :completed, project:)
    requirement = create(:pre_commit_requirement, project:, account: project.account)

    result = described_class.call(source_run:, requirement:, actor: project.created_by)

    expect(result).not_to be_success
    expect(result.agent_run).to be_nil
  end
end
