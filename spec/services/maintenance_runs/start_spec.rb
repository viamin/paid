# frozen_string_literal: true

require "rails_helper"

RSpec.describe MaintenanceRuns::Start do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:, created_by: owner) }
  let(:pinned_revision) { "a" * 40 }

  before do
    allow(FeatureFlags).to receive(:enabled?).and_call_original
    allow(FeatureFlags).to receive(:enabled?).with(:maintenance_runs, project:).and_return(true)
    allow(AgentRuns::RunnerResolver).to receive(:call)
      .with(project: project, goal: "maintenance")
      .and_return([ nil, "claude_code" ])
    allow(project.client).to receive(:ref)
      .with(project.full_name, "heads/#{project.default_branch}")
      .and_return(Struct.new(:object).new(Struct.new(:sha).new(pinned_revision)))
    allow(ProcessRunQueueJob).to receive(:perform_later)
  end

  def start(**kwargs)
    described_class.call(project:, actor: owner, **kwargs)
  end

  # @spec MAINT-002
  it "refuses admission while the maintenance_runs guard is disabled" do
    allow(FeatureFlags).to receive(:enabled?).with(:maintenance_runs, project:).and_return(false)

    expect {
      start(guidance: "Audit workflow A for shared code")
    }.to raise_error(MaintenanceRuns::Start::FeatureDisabledError)

    expect(project.agent_runs.where(goal: "maintenance")).to be_empty
  end

  # @spec MAINT-011
  it "requires a recipe objective or nonblank free-text guidance" do
    expect { start(scope: "app/workflows/a.rb") }
      .to raise_error(MaintenanceRuns::Start::MissingObjectiveError)

    expect { start(guidance: "   ") }
      .to raise_error(MaintenanceRuns::Start::MissingObjectiveError)
  end

  # @spec MAINT-011
  it "rejects an unknown recipe objective with an actionable error" do
    expect { start(objective: "not_a_recipe") }
      .to raise_error(MaintenanceRuns::Start::UnknownObjectiveError, /not_a_recipe/)
  end

  # @spec MAINT-010
  it "creates a queued manual maintenance run without an issue or pull request" do
    run = start(guidance: "Audit workflows A and B for shared code extraction")

    expect(run).to have_attributes(
      goal: "maintenance",
      status: "queued",
      trigger_type: "manual",
      issue: nil,
      source_pull_request_number: nil,
      project: project,
      initiating_user: owner
    )
    expect(run.custom_prompt).to be_present
    expect(ProcessRunQueueJob).to have_received(:perform_later)
  end

  # @spec MAINT-015
  it "snapshots objective, scope, guidance, recipe version, pinned revision, and limits at start" do
    run = start(
      objective: "unnecessary_code",
      guidance: "Preserve independent retry policies",
      scope: "app/workflows/a.rb, app/workflows/b.rb"
    )

    expect(run).to have_attributes(
      maintenance_objective: "unnecessary_code",
      maintenance_guidance: "Preserve independent retry policies",
      maintenance_scope: "app/workflows/a.rb, app/workflows/b.rb",
      maintenance_scope_kind: "named",
      maintenance_recipe_version: "1",
      maintenance_pinned_revision: pinned_revision
    )
    expect(run.maintenance_limits).to include("max_execution_seconds" => project.max_execution_seconds)
    expect(run.agent_type).to eq("claude_code")
  end

  # @spec MAINT-015
  it "refuses admission when the default branch does not resolve to a commit SHA" do
    allow(project.client).to receive(:ref)
      .with(project.full_name, "heads/#{project.default_branch}")
      .and_return(Struct.new(:object).new(Struct.new(:sha).new("main")))

    expect { start(guidance: "Audit the repository") }
      .to raise_error(MaintenanceRuns::Start::RevisionUnavailableError, /commit SHA/)
  end

  # @spec MAINT-014
  it "records an explicit broad-scope investigation when no scope is supplied" do
    run = start(guidance: "Audit the repository for unused code")

    expect(run.maintenance_scope).to be_nil
    expect(run.maintenance_scope_kind).to eq("broad")
  end

  it "refuses to start when no runnable runner can be resolved" do
    allow(AgentRuns::RunnerResolver).to receive(:call)
      .with(project: project, goal: "maintenance")
      .and_return([ nil, nil ])

    expect { start(guidance: "Audit workflow A") }
      .to raise_error(MaintenanceRuns::Start::NoRunnableRunnerError)
  end
end
