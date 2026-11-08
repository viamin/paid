# frozen_string_literal: true

require "rails_helper"

RSpec.describe TechnicalPrerequisites::StartValidation do
  # @spec PARTIAL-CLOSEOUT-032
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

  # @spec PARTIAL-CLOSEOUT-032
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

  # @spec PARTIAL-CLOSEOUT-032
  it "refuses a disabled recipe" do
    project = create(:project)
    source_run = create(:agent_run, :completed, project:, base_commit_sha: "a" * 40)
    requirement = create(:pre_commit_requirement, project:, account: project.account, enabled: false)

    result = described_class.call(source_run:, requirement:, actor: project.created_by)

    expect(result).not_to be_success
    expect(result.agent_run).to be_nil
  end

  # @spec PARTIAL-CLOSEOUT-042
  it "does not queue a reviewed performance comparison while project scheduling is paused" do
    project = create(:project, scheduler_paused_at: Time.current)
    source_run = create(:agent_run, :completed, project:, base_commit_sha: "d" * 40, result_commit_sha: "c" * 40)
    create(:issue, :pull_request, project:, github_number: source_run.pull_request_number,
      last_scanned_head_sha: source_run.result_commit_sha)
    requirement = create(:pre_commit_requirement, project:, account: project.account,
      check_type: "performance_measurement", command: "bin/measure", measurement_recipe: {
        "baseline_commit_sha" => "b" * 40,
        "workload" => { "identity" => "inbox-fixture", "provenance" => "reviewed fixture v1", "representative" => true },
        "metrics" => [ "wall_ms" ], "samples" => 3, "environment" => "isolated-linux",
        "budget_seconds" => 60, "artifact_contract" => [ "raw_samples", "comparison" ]
      })

    result = described_class.call(source_run:, requirement:, actor: project.created_by, criterion: "Inbox allocations")

    expect(result).not_to be_success
    expect(result.agent_run).to be_nil
    expect(result.message).to eq("Project scheduling is paused; resume it before running performance measurement.")
    expect(TechnicalPrerequisiteValidationJob).not_to have_been_enqueued
  end

  # @spec PARTIAL-CLOSEOUT-042
  it "does not queue a reviewed performance comparison while account scheduling is paused" do
    project = create(:project)
    project.account.update!(scheduler_paused_at: Time.current)
    source_run = create(:agent_run, :completed, project:, base_commit_sha: "d" * 40, result_commit_sha: "c" * 40)
    create(:issue, :pull_request, project:, github_number: source_run.pull_request_number,
      last_scanned_head_sha: source_run.result_commit_sha)
    requirement = create(:pre_commit_requirement, project:, account: project.account,
      check_type: "performance_measurement", command: "bin/measure", measurement_recipe: {
        "baseline_commit_sha" => "b" * 40,
        "workload" => { "identity" => "inbox-fixture", "provenance" => "reviewed fixture v1", "representative" => true },
        "metrics" => [ "wall_ms" ], "samples" => 3, "environment" => "isolated-linux",
        "budget_seconds" => 60, "artifact_contract" => [ "raw_samples", "comparison" ]
      })

    result = described_class.call(source_run:, requirement:, actor: project.created_by, criterion: "Inbox allocations")

    expect(result).not_to be_success
    expect(result.agent_run).to be_nil
    expect(result.message).to eq("Account scheduling is paused; resume it before running performance measurement.")
    expect(TechnicalPrerequisiteValidationJob).not_to have_been_enqueued
  end

  # @spec PARTIAL-CLOSEOUT-032
  it "queues a non-performance validation while project scheduling is paused" do
    project = create(:project, scheduler_paused_at: Time.current)
    source_run = create(:agent_run, :completed, project:, base_commit_sha: "a" * 40)
    requirement = create(:pre_commit_requirement, project:, account: project.account, command: "bin/audit --quick")

    result = described_class.call(source_run:, requirement:, actor: project.created_by)

    expect(result).to be_success
    expect(TechnicalPrerequisiteValidationJob).to have_been_enqueued.with(result.agent_run.id)
  end

  # @spec PARTIAL-CLOSEOUT-032
  it "preserves reviewed recipe shell syntax for the isolated execution environment" do
    project = create(:project)
    source_run = create(:agent_run, :completed, project:, base_commit_sha: "a" * 40)
    command = "RAILS_ENV=test bundle exec rspec && echo done | tee validation.log"
    requirement = create(:pre_commit_requirement, project:, account: project.account, command:)

    result = described_class.call(source_run:, requirement:, actor: project.created_by)

    expect(result).to be_success
    expect(result.agent_run.external_metadata.dig("technical_prerequisite_validation", "command")).to eq(command)
  end

  # @spec PARTIAL-CLOSEOUT-032
  it "provisions only the tool named by a criterion-specific validation" do
    project = create(:project)
    source_run = create(:agent_run, :completed, project:, base_commit_sha: "a" * 40)
    AgentRun.where(id: source_run.id).update_all(
      tool_sidecar_snapshot: [ { "name" => "expected-tool" }, { "name" => "unrelated-tool" } ],
      mcp_server_snapshot: [ { "name" => "unrelated-mcp" } ]
    )
    source_run.reload
    requirement = create(:pre_commit_requirement, project:, account: project.account)

    result = described_class.call(source_run:, requirement:, actor: project.created_by,
      criterion: "Check expected tool", tool_name: "expected-tool")

    expect(result.agent_run.tool_sidecar_snapshot).to eq([ { "name" => "expected-tool" } ])
    expect(result.agent_run.mcp_server_snapshot).to be_empty
  end

  # @spec PARTIAL-CLOSEOUT-032
  it "refuses a source run without a pinned checkout" do
    project = create(:project)
    source_run = create(:agent_run, :completed, project:)
    requirement = create(:pre_commit_requirement, project:, account: project.account)

    result = described_class.call(source_run:, requirement:, actor: project.created_by)

    expect(result).not_to be_success
    expect(result.agent_run).to be_nil
  end

  # @spec PARTIAL-CLOSEOUT-032
  it "refuses a prior validation as the source run" do
    project = create(:project)
    source_run = create(:agent_run, :completed, project:, goal: "technical_prerequisite_validation", base_commit_sha: "a" * 40)
    requirement = create(:pre_commit_requirement, project:, account: project.account)

    result = described_class.call(source_run:, requirement:, actor: project.created_by)

    expect(result).not_to be_success
    expect(result.message).to include("original implementation run")
  end

  # @spec PARTIAL-CLOSEOUT-042
  it "queues one deduplicated, pinned performance comparison with its reviewed recipe contract" do
    project = create(:project)
    source_run = create(:agent_run, :completed, project:, base_commit_sha: "d" * 40, result_commit_sha: "c" * 40)
    create(:issue, :pull_request, project:, github_number: source_run.pull_request_number,
      last_scanned_head_sha: source_run.result_commit_sha)
    requirement = create(:pre_commit_requirement, project:, account: project.account,
      check_type: "performance_measurement", command: "bin/measure", measurement_recipe: {
          "baseline_commit_sha" => "b" * 40, "workload" => { "identity" => "inbox-fixture", "provenance" => "reviewed fixture v1", "representative" => true },
          "metrics" => [ "wall_ms", "peak_rss_bytes" ], "samples" => 3,
          "environment" => "isolated-linux", "budget_seconds" => 60,
          "artifact_contract" => [ "raw_samples", "comparison" ]
      })

    first = described_class.call(source_run:, requirement:, actor: project.created_by, criterion: "Inbox allocations")
    project.update!(scheduler_paused_at: Time.current)
    second = described_class.call(source_run:, requirement:, actor: project.created_by, criterion: "Inbox allocations")

    expect(first).to be_success
    expect(second).to be_success
    expect(second.agent_run).to eq(first.agent_run)
    expect(first.agent_run.base_commit_sha).to eq("c" * 40)
    expect(first.agent_run.external_metadata.dig("technical_prerequisite_validation", "performance_measurement"))
      .to include("baseline_commit_sha" => "b" * 40, "current_commit_sha" => "c" * 40, "samples" => 3)
  end

  # @spec PARTIAL-CLOSEOUT-042
  it "keeps a performance comparison unknown when the linked pull request head has advanced" do
    project = create(:project)
    source_run = create(:agent_run, :completed, project:, base_commit_sha: "d" * 40, result_commit_sha: "c" * 40)
    create(:issue, :pull_request, project:, github_number: source_run.pull_request_number,
      last_scanned_head_sha: "e" * 40)
    requirement = create(:pre_commit_requirement, project:, account: project.account,
      check_type: "performance_measurement", command: "bin/measure", measurement_recipe: {
        "baseline_commit_sha" => "b" * 40,
        "workload" => { "identity" => "inbox-fixture", "provenance" => "reviewed fixture v1", "representative" => true },
        "metrics" => [ "wall_ms" ], "samples" => 3,
        "environment" => "isolated-linux", "budget_seconds" => 60,
        "artifact_contract" => [ "raw_samples", "comparison" ]
      })

    result = described_class.call(source_run:, requirement:, actor: project.created_by, criterion: "Inbox allocations")

    expect(result).not_to be_success
    expect(result.agent_run).to be_nil
    expect(result.message).to include("head changed")
    expect(TechnicalPrerequisiteValidationJob).not_to have_been_enqueued
  end

  # @spec PARTIAL-CLOSEOUT-042
  it "refuses a performance comparison when the source run produced no revision to measure" do
    project = create(:project)
    source_run = create(:agent_run, :completed, project:, base_commit_sha: "a" * 40, result_commit_sha: nil)
    requirement = create(:pre_commit_requirement, project:, account: project.account,
      check_type: "performance_measurement", command: "bin/measure", measurement_recipe: {
          "baseline_commit_sha" => "b" * 40, "workload" => { "identity" => "inbox-fixture", "provenance" => "reviewed fixture v1", "representative" => true },
          "metrics" => [ "wall_ms" ], "samples" => 3,
          "environment" => "isolated-linux", "budget_seconds" => 60,
          "artifact_contract" => [ "raw_samples", "comparison" ]
      })

    result = described_class.call(source_run:, requirement:, actor: project.created_by, criterion: "Inbox allocations")

    expect(result).not_to be_success
    expect(result.agent_run).to be_nil
    expect(result.message).to include("produced revision")
  end

  # @spec PARTIAL-CLOSEOUT-042
  it "refuses an incomplete or nonrepresentative performance recipe" do
    project = create(:project)
    source_run = create(:agent_run, :completed, project:, base_commit_sha: "a" * 40)
    requirement = create(:pre_commit_requirement, project:, account: project.account,
      check_type: "performance_measurement", command: "bin/measure", measurement_recipe: { "samples" => 1 })

    result = described_class.call(source_run:, requirement:, actor: project.created_by)

    expect(result).not_to be_success
    expect(result.message).to include("reviewed performance recipe")
  end

  # @spec PARTIAL-CLOSEOUT-042
  it "refuses a persisted non-object performance recipe without raising" do
    project = create(:project)
    source_run = create(:agent_run, :completed, project:, base_commit_sha: "a" * 40, result_commit_sha: "c" * 40)
    requirement = create(:pre_commit_requirement, project:, account: project.account,
      check_type: "performance_measurement", command: "bin/measure")
    requirement.update_column(:measurement_recipe, "not-a-json-object")

    result = described_class.call(source_run:, requirement: requirement.reload, actor: project.created_by)

    expect(result).not_to be_success
    expect(result.message).to include("reviewed performance recipe")
  end

  # @spec PARTIAL-CLOSEOUT-042
  it "refuses a performance recipe whose baseline is the produced revision itself" do
    project = create(:project)
    source_run = create(:agent_run, :completed, project:, base_commit_sha: "a" * 40, result_commit_sha: "c" * 40)
    requirement = create(:pre_commit_requirement, project:, account: project.account,
      check_type: "performance_measurement", command: "bin/measure", measurement_recipe: {
          "baseline_commit_sha" => "C" * 40, "workload" => { "identity" => "inbox-fixture", "provenance" => "reviewed fixture v1", "representative" => true },
          "metrics" => [ "wall_ms" ], "samples" => 3,
          "environment" => "isolated-linux", "budget_seconds" => 60,
          "artifact_contract" => [ "raw_samples", "comparison" ]
      })

    result = described_class.call(source_run:, requirement:, actor: project.created_by)

    expect(result).not_to be_success
    expect(result.message).to include("reviewed performance recipe")
  end

  # @spec PARTIAL-CLOSEOUT-042
  it "refuses recipe values that only coerce, because execution consumes them strictly" do
    project = create(:project)
    source_run = create(:agent_run, :completed, project:, base_commit_sha: "a" * 40, result_commit_sha: "c" * 40)
    complete_recipe = {
      "baseline_commit_sha" => "b" * 40, "workload" => { "identity" => "inbox-fixture", "provenance" => "reviewed fixture v1", "representative" => true },
      "metrics" => [ "wall_ms" ], "samples" => 3,
      "environment" => "isolated-linux", "budget_seconds" => 60,
      "artifact_contract" => [ "raw_samples", "comparison" ]
    }

    aggregate_failures do
      { "metrics" => "wall_ms", "samples" => "3", "budget_seconds" => "1e3" }.each do |key, value|
        requirement = create(:pre_commit_requirement, project:, account: project.account,
          check_type: "performance_measurement", command: "bin/measure",
          measurement_recipe: complete_recipe.merge(key => value))

        result = described_class.call(source_run:, requirement:, actor: project.created_by, criterion: "Inbox allocations")

        expect(result).not_to be_success
        expect(result.message).to include("reviewed performance recipe")
      end
    end
  end
end
