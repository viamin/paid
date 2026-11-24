# frozen_string_literal: true

require "rails_helper"

RSpec.describe CycleAnalyses::Start do
  def cycle_for(user)
    project = create(:project, account: user.account, created_by: user)
    first = create(:issue, project:, github_state: "open")
    second = create(:issue, project:, github_state: "open")
    create_legacy_issue_dependency(issue: first, depends_on_issue: second)
    create_legacy_issue_dependency(issue: second, depends_on_issue: first)
    Issues::DependencyCycles.call(account: user.account).sole
  end

  # @spec AUTO-PICK-QUEUE-016 AUTO-PICK-QUEUE-017
  it "starts occurrences whose CRC exceeds PostgreSQL's signed integer range and persists prompt evidence" do
    user = create(:user)
    project = create(:project, account: user.account, created_by: user)
    create(:runner, user:, enabled_for_agent_runs: true)
    first = create(:issue, project:, github_state: "open", body: "First body")
    second = create(:issue, project:, github_state: "open", body: "Second body")
    first_edge = create_legacy_issue_dependency(issue: first, depends_on_issue: second)
    second_edge = create_legacy_issue_dependency(issue: second, depends_on_issue: first)
    cycle = Issues::DependencyCycles.call(account: user.account).sole
    occurrence = (1..).lazy.map { |suffix| "#{cycle.occurrence}:#{suffix}" }
      .find { |candidate| Zlib.crc32(candidate) > 2_147_483_647 }
    cycle = cycle.with(occurrence:)

    result = described_class.call(cycle:, actor: user)

    expect(result).to be_success
    snapshot = result.agent_run.external_metadata.fetch(CycleAnalyses::METADATA_KEY)
    expect(snapshot.fetch("issues").pluck("id", "body")).to contain_exactly(
      [ first.id, "First body" ], [ second.id, "Second body" ]
    )
    expect(snapshot.fetch("effective_edges").pluck("id")).to contain_exactly(first_edge.id, second_edge.id)
  end

  # @spec AUTO-PICK-QUEUE-016
  it "does not queue another analysis for a completed unchanged occurrence" do
    user = create(:user)
    create(:runner, user:, enabled_for_agent_runs: true)
    cycle = cycle_for(user)
    completed = create(:agent_run, :completed, project: cycle.project, initiating_user: user,
      goal: AgentRun::CYCLE_ANALYSIS_GOAL,
      external_metadata: { CycleAnalyses::METADATA_KEY => CycleAnalyses::Snapshot.call(cycle:) })

    result = nil
    expect { result = described_class.call(cycle:, actor: user) }.not_to change(AgentRun, :count)

    expect(result).not_to be_success
    expect(result.agent_run).to eq(completed)
  end

  # @spec AUTO-PICK-QUEUE-019
  it "requeues a pending synchronization run for confirmation without creating another run" do
    user = create(:user)
    create(:runner, user:, enabled_for_agent_runs: true)
    cycle = cycle_for(user)
    pending = create(:agent_run, :completed, project: cycle.project, initiating_user: user,
      goal: AgentRun::CYCLE_ANALYSIS_GOAL,
      external_metadata: { CycleAnalyses::METADATA_KEY => CycleAnalyses::Snapshot.call(cycle:) },
      verification_result: { CycleAnalyses::RESULT_KEY => { "repair" => { "status" => "pending_sync" } } })

    result = nil
    expect { result = described_class.call(cycle:, actor: user) }.not_to change(AgentRun, :count)

    expect(result).to be_success
    expect(result.agent_run).to eq(pending)
    expect(pending.reload).to have_attributes(status: "queued", completed_at: nil)
  end

  # @spec AUTO-PICK-QUEUE-016
  it "permits a new analysis after the graph occurrence changes" do
    user = create(:user)
    create(:runner, user:, enabled_for_agent_runs: true)
    cycle = cycle_for(user)
    create(:agent_run, :completed, project: cycle.project, initiating_user: user,
      goal: AgentRun::CYCLE_ANALYSIS_GOAL,
      external_metadata: { CycleAnalyses::METADATA_KEY => CycleAnalyses::Snapshot.call(cycle:) })

    changed_cycle = cycle.with(occurrence: "#{cycle.occurrence}:changed")

    result = nil
    expect { result = described_class.call(cycle: changed_cycle, actor: user) }.to change(AgentRun, :count).by(1)
    expect(result).to be_success
  end

  # @spec AUTO-PICK-QUEUE-025
  it "records an automatic trigger on the scheduled run" do
    user = create(:user)
    create(:runner, user:, enabled_for_agent_runs: true)
    cycle = cycle_for(user)

    result = described_class.call(cycle:, actor: user, trigger: :automatic)

    expect(result).to be_success
    expect(result.agent_run).to have_attributes(trigger_type: "automatic", initiating_user: user)
  end

  # @spec AUTO-PICK-QUEUE-025
  it "never schedules a second automatic attempt for an unchanged occurrence, including after failure" do
    user = create(:user)
    create(:runner, user:, enabled_for_agent_runs: true)
    cycle = cycle_for(user)
    create(:agent_run, :failed, project: cycle.project, initiating_user: user,
      goal: AgentRun::CYCLE_ANALYSIS_GOAL,
      external_metadata: { CycleAnalyses::METADATA_KEY => CycleAnalyses::Snapshot.call(cycle:) })

    result = nil
    expect { result = described_class.call(cycle:, actor: user, trigger: :automatic) }.not_to change(AgentRun, :count)

    expect(result).not_to be_success
    expect(result.status).to eq(:duplicate)
  end

  # @spec AUTO-PICK-QUEUE-025 AUTO-PICK-QUEUE-019
  it "never resumes a pending-sync confirmation automatically" do
    user = create(:user)
    create(:runner, user:, enabled_for_agent_runs: true)
    cycle = cycle_for(user)
    pending = create(:agent_run, :completed, project: cycle.project, initiating_user: user,
      goal: AgentRun::CYCLE_ANALYSIS_GOAL,
      external_metadata: { CycleAnalyses::METADATA_KEY => CycleAnalyses::Snapshot.call(cycle:) },
      verification_result: { CycleAnalyses::RESULT_KEY => { "repair" => { "status" => "pending_sync" } } })

    result = nil
    expect { result = described_class.call(cycle:, actor: user, trigger: :automatic) }.not_to change(AgentRun, :count)

    expect(result).not_to be_success
    expect(pending.reload).to have_attributes(status: "completed")
  end

  # @spec AUTO-PICK-QUEUE-025
  it "bounds automatic attempts for a recurring cycle fingerprint" do
    user = create(:user)
    create(:runner, user:, enabled_for_agent_runs: true)
    cycle = cycle_for(user)
    described_class::AUTOMATIC_RUNS_PER_FINGERPRINT.times do |index|
      described_class.call(cycle: cycle.with(occurrence: "#{cycle.occurrence}:r#{index}"), actor: user,
        trigger: :automatic)
    end

    result = nil
    expect {
      result = described_class.call(cycle: cycle.with(occurrence: "#{cycle.occurrence}:next"), actor: user,
        trigger: :automatic)
    }.not_to change(AgentRun, :count)

    expect(result.status).to eq(:recurrence_bound)
  end
end
