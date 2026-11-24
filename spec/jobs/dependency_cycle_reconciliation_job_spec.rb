# frozen_string_literal: true

require "rails_helper"

RSpec.describe DependencyCycleReconciliationJob do
  let!(:initial_account_boundary) { Account.maximum(:id) }

  before do
    allow(Rails.logger).to receive(:info)
    allow(Rails.logger).to receive(:warn)
    allow(Dashboard::CacheVersion).to receive(:bump)
  end

  # @spec AUTO-PICK-QUEUE-014
  it "logs an empty page when no accounts remain after the cursor" do
    described_class.perform_now(after_account_id: initial_account_boundary)

    expect(Rails.logger).to have_received(:info).with(
      hash_including(
        message: "dependency_cycles.reconciliation_page_completed",
        account_count: 0,
        reconciled_count: 0,
        unavailable_count: 0,
        through_account_id: initial_account_boundary,
        duration_ms: a_kind_of(Integer),
        allocations: a_kind_of(Integer)
      )
    )
  end

  # @spec AUTO-PICK-QUEUE-014
  it "reconciles each account in a captured cycle once through bounded continuations" do
    stub_const("DependencyCycleReconciliationJob::ACCOUNT_PAGE_SIZE", 2)
    accounts = Array.new(3) { create(:account) }
    calls = []
    continuations = []
    allow(Issues::DependencyCycles).to receive(:call) { |account:| calls << account.id; [] }
    allow(described_class).to receive(:perform_later) { |**arguments| continuations << arguments }

    described_class.perform_now(after_account_id: initial_account_boundary)
    described_class.perform_now(**continuations.shift)

    expect(calls).to eq(accounts.map(&:id))
    expect(Dashboard::CacheVersion).to have_received(:bump).exactly(3).times
    expect(Rails.logger).to have_received(:info).with(
      hash_including(
        message: "dependency_cycles.reconciliation_page_completed",
        account_count: 2,
        duration_ms: a_kind_of(Integer),
        allocations: a_kind_of(Integer)
      )
    )
  end

  # @spec AUTO-PICK-QUEUE-014
  it "retries an unavailable account after a bounded delay without invalidating its cache first" do
    stub_const("DependencyCycleReconciliationJob::ACCOUNT_PAGE_SIZE", 2)
    first, unavailable, later = Array.new(3) { create(:account) }
    calls = []
    continuations = []
    attempts = 0
    allow(Issues::DependencyCycles).to receive(:call) do |account:|
      calls << account.id
      raise Issues::DependencyCycles::CoverageUnavailable, "database unavailable" if account == unavailable && (attempts += 1) == 1
      []
    end
    stub_first_retry_delay(continuations)

    described_class.perform_now(after_account_id: initial_account_boundary)

    expect(continuations).to contain_exactly(after_account_id: first.id, through_account_id: later.id, unavailable_retries: 1)
    expect(described_class).not_to have_received(:perform_later)
    expect(Dashboard::CacheVersion).to have_received(:bump).with(first, scope: Dashboard::CacheVersion::LISTS_SCOPE)
    expect(Dashboard::CacheVersion).not_to have_received(:bump).with(unavailable, scope: Dashboard::CacheVersion::LISTS_SCOPE)

    described_class.perform_now(**continuations.shift)

    expect(calls).to eq([ first.id, unavailable.id, unavailable.id, later.id ])
    expect(Dashboard::CacheVersion).to have_received(:bump).with(unavailable, scope: Dashboard::CacheVersion::LISTS_SCOPE)
    expect(Dashboard::CacheVersion).to have_received(:bump).with(later, scope: Dashboard::CacheVersion::LISTS_SCOPE)
  end

  # @spec AUTO-PICK-QUEUE-014
  it "backs off repeated unavailable-account retries up to a bounded cap without advancing the cursor" do
    stub_const("DependencyCycleReconciliationJob::ACCOUNT_PAGE_SIZE", 1)
    cursor_account = create(:account)
    unavailable = create(:account)
    later = create(:account)
    calls = []
    waits = []
    continuations = []
    allow(Issues::DependencyCycles).to receive(:call) do |account:|
      calls << account.id
      raise Issues::DependencyCycles::CoverageUnavailable, "database unavailable" if account == unavailable
      []
    end
    stub_backoff_delays(continuations, waits)

    described_class.perform_now(after_account_id: cursor_account.id)
    expect_unavailable_continuation(continuations, cursor_account.id, later.id, 1)
    5.times { described_class.perform_now(**continuations.shift) }

    expect(waits).to eq([ 1.minute, 2.minutes, 4.minutes, 8.minutes, 10.minutes, 10.minutes ])
    expect(continuations).to contain_exactly(after_account_id: cursor_account.id, through_account_id: later.id, unavailable_retries: 6)
    expect(calls).to all(eq(unavailable.id))
    expect(described_class).not_to have_received(:perform_later)
  end

  # @spec AUTO-PICK-QUEUE-014
  it "defers accounts created after the captured boundary until the next cycle" do
    stub_const("DependencyCycleReconciliationJob::ACCOUNT_PAGE_SIZE", 1)
    first, second = Array.new(2) { create(:account) }
    calls = []
    continuations = []
    allow(Issues::DependencyCycles).to receive(:call) { |account:| calls << account.id; [] }
    allow(described_class).to receive(:perform_later) { |**arguments| continuations << arguments }

    described_class.perform_now(after_account_id: initial_account_boundary)
    added_during_cycle = create(:account)
    described_class.perform_now(**continuations.shift)

    expect(calls).to eq([ first.id, second.id ])
    expect(continuations).to be_empty

    described_class.perform_now(after_account_id: initial_account_boundary)
    described_class.perform_now(**continuations.shift)
    described_class.perform_now(**continuations.shift)

    expect(calls).to include(added_during_cycle.id)
  end

  # @spec AUTO-PICK-QUEUE-025
  it "schedules one automatic cycle analysis for a delegated project's newly detected cycle" do
    account = create(:account)
    owner = create(:user, :owner, account: account)
    project = create(:project, account: account, created_by: owner)
    delegate_repair(project, selected_by: owner)
    create_cycle(project)

    described_class.perform_now(after_account_id: initial_account_boundary)

    run = AgentRun.find_by(goal: AgentRun::CYCLE_ANALYSIS_GOAL)
    expect(run).to have_attributes(project: project, trigger_type: "automatic", status: "queued",
      initiating_user: owner)
    expect(run.external_metadata.fetch(CycleAnalyses::METADATA_KEY).fetch("occurrence"))
      .to eq(Issues::DependencyCycles.call(account: account).sole.occurrence)
  end

  def delegate_repair(project, selected_by:)
    FeatureFlags.enable!(:automation_phases, project: project)
    FeatureFlags.enable!(:project_delegation, project: project)
    project.update!(Automation::PhaseSettings::SETTINGS_KEY => {
      Automation::PhaseSettings::PHASES_KEY => { Automation::Phases::CODING => true }
    })
    create(:project_delegation_posture, project: project, level: ProjectDelegation::Posture::BOUNDED_DELIVERY,
      selected_by: selected_by)
  end

  def create_cycle(project)
    first = create(:issue, project: project, github_state: "open")
    second = create(:issue, project: project, github_state: "open")
    create_legacy_issue_dependency(issue: first, depends_on_issue: second)
    create_legacy_issue_dependency(issue: second, depends_on_issue: first)
  end

  def stub_first_retry_delay(continuations)
    scheduler = instance_double(ActiveJob::ConfiguredJob)
    allow(scheduler).to receive(:perform_later) { |**arguments| continuations << arguments }
    allow(described_class).to receive(:perform_later)
    allow(described_class).to receive(:set).with(wait: described_class::UNAVAILABLE_RETRY_BASE_DELAY).and_return(scheduler)
  end

  def stub_backoff_delays(continuations, waits)
    allow(described_class).to receive(:perform_later)
    allow(described_class).to receive(:set) do |wait:|
      waits << wait
      scheduler = instance_double(ActiveJob::ConfiguredJob)
      allow(scheduler).to receive(:perform_later) { |**arguments| continuations << arguments }
      scheduler
    end
  end

  def expect_unavailable_continuation(continuations, after_account_id, through_account_id, unavailable_retries)
    expect(continuations).to contain_exactly(after_account_id:, through_account_id:, unavailable_retries:)
  end
end
