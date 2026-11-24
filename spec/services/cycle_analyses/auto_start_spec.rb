# frozen_string_literal: true

require "rails_helper"

# Automatic bounded cycle analysis under effective project policy (#4871):
# detection schedules one automatic run per newly detected cycle occurrence
# only when every represented project's effective policy delegates the bounded
# repair action and one identified actor holds authority across the whole
# cycle. Bounds and Inbox presentation live in CycleAnalyses::Start and the
# existing analysis/repair services.
# @spec AUTO-PICK-QUEUE-025
RSpec.describe CycleAnalyses::AutoStart do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account: account) }

  def delegate_repair(project, selected_by: nil)
    FeatureFlags.enable!(:automation_phases, project: project)
    FeatureFlags.enable!(:project_delegation, project: project)
    project.update!(
      Automation::PhaseSettings::SETTINGS_KEY => {
        Automation::PhaseSettings::PHASES_KEY => {
          Automation::Phases::CODING => true
        }
      }
    )
    create(:project_delegation_posture, project: project, level: ProjectDelegation::Posture::BOUNDED_DELIVERY,
      selected_by: selected_by || project.created_by)
  end

  def cycle_for(account, project:)
    first = create(:issue, project: project, github_state: "open")
    second = create(:issue, project: project, github_state: "open")
    create_legacy_issue_dependency(issue: first, depends_on_issue: second)
    create_legacy_issue_dependency(issue: second, depends_on_issue: first)
    Issues::DependencyCycles.call(account: account).sole
  end

  before { create(:runner, user: owner, enabled_for_agent_runs: true) }

  # @spec AUTO-PICK-QUEUE-025
  it "schedules one automatic run against the current occurrence for a delegated project" do
    project = create(:project, account: account, created_by: owner)
    delegate_repair(project)
    cycle = cycle_for(account, project:)

    expect { described_class.call(cycles: [ cycle ]) }.to change(AgentRun, :count).by(1)

    run = AgentRun.last
    expect(run).to have_attributes(
      project: project, goal: AgentRun::CYCLE_ANALYSIS_GOAL, status: "queued",
      trigger_type: "automatic", initiating_user: owner, synthetic: true
    )
    expect(run.external_metadata.fetch(CycleAnalyses::METADATA_KEY).fetch("occurrence")).to eq(cycle.occurrence)
  end

  # @spec AUTO-PICK-QUEUE-025
  it "keeps manual start available when policy does not delegate" do
    project = create(:project, account: account, created_by: owner)
    FeatureFlags.enable!(:automation_phases, project: project)
    cycle = cycle_for(account, project:)

    expect { described_class.call(cycles: [ cycle ]) }.not_to change(AgentRun, :count)

    result = CycleAnalyses::Start.call(cycle:, actor: owner)
    expect(result).to be_success
    expect(result.agent_run.trigger_type).to eq("manual")
  end

  # @spec AUTO-PICK-QUEUE-025
  it "does not infer consent from a stored broadened selection while the rollout guard is off" do
    project = create(:project, account: account, created_by: owner)
    delegate_repair(project)
    FeatureFlags.disable!(:automation_phases, project: project)
    cycle = cycle_for(account, project:)

    expect { described_class.call(cycles: [ cycle ]) }.not_to change(AgentRun, :count)
  end

  # @spec AUTO-PICK-QUEUE-025
  it "requires every represented project of a cross-project cycle to delegate" do
    delegated = create(:project, account: account, created_by: owner)
    conservative = create(:project, account: account, created_by: owner)
    delegate_repair(delegated)
    FeatureFlags.enable!(:automation_phases, project: conservative)
    FeatureFlags.enable!(:project_delegation, project: conservative)

    first = create(:issue, project: delegated, github_state: "open")
    second = create(:issue, project: conservative, github_state: "open")
    create_legacy_issue_dependency(issue: first, depends_on_issue: second)
    create_legacy_issue_dependency(issue: second, depends_on_issue: first)
    cycle = Issues::DependencyCycles.call(account: account).sole

    expect { described_class.call(cycles: [ cycle ]) }.not_to change(AgentRun, :count)
  end

  # @spec AUTO-PICK-QUEUE-025
  it "starts a fully delegated cross-project cycle under one actor authorized for both projects" do
    first_project = create(:project, account: account, created_by: owner)
    second_project = create(:project, account: account, created_by: owner)
    delegate_repair(first_project)
    delegate_repair(second_project)

    first = create(:issue, project: first_project, github_state: "open")
    second = create(:issue, project: second_project, github_state: "open")
    create_legacy_issue_dependency(issue: first, depends_on_issue: second)
    create_legacy_issue_dependency(issue: second, depends_on_issue: first)
    cycle = Issues::DependencyCycles.call(account: account).sole

    expect { described_class.call(cycles: [ cycle ]) }.to change(AgentRun, :count).by(1)

    run = AgentRun.last
    expect(run.trigger_type).to eq("automatic")
    expect(run.external_metadata.fetch(CycleAnalyses::METADATA_KEY).fetch("project_ids"))
      .to contain_exactly(first_project.id, second_project.id)
  end

  # @spec AUTO-PICK-QUEUE-025
  it "does not start when no single actor holds authority for every represented project" do
    unauthorized_first = create(:user, account: account)
    unauthorized_second = create(:user, account: account)
    first_project = create(:project, account: account, created_by: unauthorized_first)
    second_project = create(:project, account: account, created_by: unauthorized_second)
    delegate_repair(first_project, selected_by: unauthorized_first)
    delegate_repair(second_project, selected_by: unauthorized_second)

    first = create(:issue, project: first_project, github_state: "open")
    second = create(:issue, project: second_project, github_state: "open")
    create_legacy_issue_dependency(issue: first, depends_on_issue: second)
    create_legacy_issue_dependency(issue: second, depends_on_issue: first)
    cycle = Issues::DependencyCycles.call(account: account).sole

    expect { described_class.call(cycles: [ cycle ]) }.not_to change(AgentRun, :count)
  end

  # @spec AUTO-PICK-QUEUE-025
  it "starts at most one automatic run for duplicate detection events" do
    project = create(:project, account: account, created_by: owner)
    delegate_repair(project)
    cycle = cycle_for(account, project:)

    described_class.call(cycles: [ cycle, cycle ])

    expect(AgentRun.where(goal: AgentRun::CYCLE_ANALYSIS_GOAL).count).to eq(1)
    expect(AgentRun.last).to have_attributes(trigger_type: "automatic", status: "queued")
  end

  # @spec AUTO-PICK-QUEUE-025
  it "never retries automatically after a failed automatic analysis" do
    project = create(:project, account: account, created_by: owner)
    delegate_repair(project)
    cycle = cycle_for(account, project:)
    described_class.call(cycles: [ cycle ])
    AgentRun.last.update!(status: "failed", error_message: "provider failed")

    expect { described_class.call(cycles: [ cycle ]) }.not_to change(AgentRun, :count)
  end

  # @spec AUTO-PICK-QUEUE-025
  it "leaves a pending-sync confirmation to ordinary synchronization instead of resuming it" do
    project = create(:project, account: account, created_by: owner)
    delegate_repair(project)
    cycle = cycle_for(account, project:)
    described_class.call(cycles: [ cycle ])
    run = AgentRun.last
    run.update!(status: "completed",
      verification_result: { CycleAnalyses::RESULT_KEY => { "repair" => { "status" => "pending_sync" } } })

    expect { described_class.call(cycles: [ cycle ]) }.not_to change(AgentRun, :count)
    expect(run.reload.status).to eq("completed")
  end

  # @spec AUTO-PICK-QUEUE-025
  it "starts one fresh automatic run after the graph changes to a new occurrence" do
    project = create(:project, account: account, created_by: owner)
    delegate_repair(project)
    cycle = cycle_for(account, project:)
    described_class.call(cycles: [ cycle ])
    AgentRun.last.update!(status: "failed", error_message: "provider failed")

    changed = cycle.with(occurrence: "#{cycle.occurrence}:changed")
    expect { described_class.call(cycles: [ changed ]) }.to change(AgentRun, :count).by(1)
    expect(AgentRun.last.external_metadata.fetch(CycleAnalyses::METADATA_KEY).fetch("occurrence"))
      .to eq(changed.occurrence)
  end

  # @spec AUTO-PICK-QUEUE-025
  it "bounds automatic attempts for a recurring cycle fingerprint" do
    project = create(:project, account: account, created_by: owner)
    delegate_repair(project)
    cycle = cycle_for(account, project:)

    occurrences = [ cycle.occurrence, *3.times.map { |index| "#{cycle.occurrence}:r#{index}" } ]
    occurrences.each { |occurrence| described_class.call(cycles: [ cycle.with(occurrence:) ]) }

    expect(AgentRun.where(goal: AgentRun::CYCLE_ANALYSIS_GOAL, trigger_type: "automatic").count)
      .to eq(CycleAnalyses::Start::AUTOMATIC_RUNS_PER_FINGERPRINT)
    expect { described_class.call(cycles: [ cycle.with(occurrence: "#{cycle.occurrence}:r9") ]) }
      .not_to change(AgentRun, :count)
  end

  it "tolerates an empty detection result" do
    expect(described_class.call(cycles: [])).to eq([])
  end
end
