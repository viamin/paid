# frozen_string_literal: true

require "rails_helper"

RSpec.describe AutoPickEligibilitySweepJob do
  let(:account) { create(:account) }
  let(:owner) { create(:user, account:) }

  def page_result(last_issue_id: nil, candidate_count: 0, more: false, created_count: 0)
    runs = Array.new(created_count) { instance_double(AgentRun, previously_new_record?: true) }
    Issues::BulkEnqueueEligible::PageResult.new(
      runs:,
      last_issue_id:,
      candidate_count:,
      more?: more
    )
  end

  def fail_first_project_page(failing_project, calls)
    attempts = 0
    allow(Issues::BulkEnqueueEligible).to receive(:call) do |project:, **|
      calls << project
      raise "queue unavailable" if project == failing_project && (attempts += 1) == 1

      page_result
    end
  end

  before do
    allow(Issues::AutoPickProjectGate).to receive(:call).and_return(true)
    allow(Rails.logger).to receive(:info)
    allow(Rails.logger).to receive(:error)
  end

  # @spec EAGER-QUEUE-017
  it "reports numeric peak RSS and the completed page counts" do
    create(:project, account:, created_by: owner, auto_pick_enabled: true)
    allow(Issues::BulkEnqueueEligible).to receive(:call).and_return(page_result(candidate_count: 2, created_count: 1))
    allow(File).to receive(:foreach).and_call_original
    allow(File).to receive(:foreach).with("/proc/self/status")
      .and_yield("Name:\truby\n").and_yield("VmHWM:\t123456 kB\n")

    described_class.perform_now

    expect(Rails.logger).to have_received(:info).with(hash_including(
      message: "auto_pick_eligibility_sweep.page_completed",
      project_count: 1, issue_count: 2, enqueued_count: 1,
      duration_ms: be >= 0, allocations: be >= 0, peak_rss_kb: 123456
    ))
  end

  # @spec EAGER-QUEUE-017
  it "reports unavailable peak RSS without failing the sweep" do
    create(:project, account:, created_by: owner, auto_pick_enabled: true)
    allow(Issues::BulkEnqueueEligible).to receive(:call).and_return(page_result)
    allow(File).to receive(:foreach).and_call_original
    allow(File).to receive(:foreach).with("/proc/self/status").and_raise(Errno::ENOENT)

    expect { described_class.perform_now }.not_to raise_error

    expect(Rails.logger).to have_received(:info).with(hash_including(
      message: "auto_pick_eligibility_sweep.page_completed", peak_rss_kb: nil
    ))
  end

  # @spec EAGER-QUEUE-017
  it "covers every project in a bounded cycle through durable continuations" do
    stub_const("AutoPickEligibilitySweepJob::PROJECT_PAGE_SIZE", 1)
    first_project = create(:project, account:, created_by: owner, auto_pick_enabled: true)
    second_project = create(:project, account:, created_by: owner, auto_pick_enabled: true)
    continuations = []
    calls = []
    allow(described_class).to receive(:perform_later) { |**arguments| continuations << arguments }
    allow(Issues::BulkEnqueueEligible).to receive(:call) { |**arguments| calls << arguments; page_result }

    described_class.perform_now

    expect(calls).to contain_exactly(hash_including(project: have_attributes(id: first_project.id), page_size: 100))
    expect(continuations).to contain_exactly(after_project_id: first_project.id, through_project_id: second_project.id)

    described_class.perform_now(**continuations.shift)

    expect(calls).to include(hash_including(project: have_attributes(id: second_project.id), page_size: 100))
  end

  # @spec EAGER-QUEUE-017
  it "resumes a large project after the last examined issue without duplicate work" do
    project = create(:project, account:, created_by: owner, auto_pick_enabled: true)
    issue = create(:issue, project:)
    continuations = []
    calls = []
    allow(described_class).to receive(:perform_later) { |**arguments| continuations << arguments }
    allow(Issues::BulkEnqueueEligible).to receive(:call) do |**arguments|
      calls << arguments
      arguments[:after_issue_id].nil? ? page_result(last_issue_id: issue.id, candidate_count: 1, more: true, created_count: 1) : page_result
    end

    described_class.perform_now
    described_class.perform_now(**continuations.shift)

    expect(calls).to include(hash_including(project: have_attributes(id: project.id), after_issue_id: issue.id, through_issue_id: issue.id, page_size: 100))
    expect(calls.size).to eq(2)
  end

  # @spec EAGER-QUEUE-017
  it "retries a failed project page from its prior cursor while continuing other projects" do
    stub_const("AutoPickEligibilitySweepJob::PROJECT_PAGE_SIZE", 2)
    failing_project = create(:project, account:, created_by: owner, auto_pick_enabled: true)
    healthy_project = create(:project, account:, created_by: owner, auto_pick_enabled: true)
    continuations = []
    calls = []
    allow(described_class).to receive(:perform_later) { |**arguments| continuations << arguments }
    fail_first_project_page(failing_project, calls)

    described_class.perform_now

    expect(calls).to include(have_attributes(id: healthy_project.id))
    expect(continuations.first.fetch(:pending_projects)).to include(
      failing_project.id.to_s => hash_including(project_id: failing_project.id, after_issue_id: nil)
    )

    described_class.perform_now(**continuations.shift)

    expect(Issues::BulkEnqueueEligible).to have_received(:call).twice.with(
      project: failing_project,
      skip_project_gate: true,
      after_issue_id: nil,
      through_issue_id: nil,
      page_size: AutoPickEligibilitySweepJob::ISSUE_PAGE_SIZE
    )
  end

  # @spec EAGER-QUEUE-017
  it "finishes the cycle snapshot when a newer project appears mid-cycle" do
    stub_const("AutoPickEligibilitySweepJob::PROJECT_PAGE_SIZE", 1)
    first_project = create(:project, account:, created_by: owner, auto_pick_enabled: true)
    second_project = create(:project, account:, created_by: owner, auto_pick_enabled: true)
    continuations = []
    calls = []
    allow(described_class).to receive(:perform_later) { |**arguments| continuations << arguments }
    allow(Issues::BulkEnqueueEligible).to receive(:call) { |**arguments| calls << arguments; page_result }

    described_class.perform_now
    added_during_cycle = create(:project, account:, created_by: owner, auto_pick_enabled: true)
    described_class.perform_now(**continuations.shift)

    expect(calls).to include(hash_including(project: have_attributes(id: second_project.id), page_size: 100))
    expect(calls).not_to include(hash_including(project: have_attributes(id: added_during_cycle.id), page_size: 100))
    expect(continuations).to be_empty
    expect(first_project.id).to be < second_project.id

    calls.clear
    3.times { described_class.perform_now(**(continuations.shift || {})) }

    expect(calls.map { |arguments| arguments.fetch(:project).id }).to eq(
      [ first_project.id, second_project.id, added_during_cycle.id ]
    )
    expect(continuations).to be_empty
  end

  # @spec EAGER-QUEUE-017
  it "retains the original project-page boundary while a pending project finishes" do
    stub_const("AutoPickEligibilitySweepJob::PROJECT_PAGE_SIZE", 3)
    projects = Array.new(3) { create(:project, account:, created_by: owner, auto_pick_enabled: true) }
    continuations = []
    calls = []
    allow(described_class).to receive(:perform_later) { |**arguments| continuations << arguments }
    allow(Issues::BulkEnqueueEligible).to receive(:call) do |project:, after_issue_id:, **|
      calls << project.id
      if project == projects.first && after_issue_id.nil?
        page_result(last_issue_id: 10, candidate_count: 1, more: true)
      else
        page_result
      end
    end

    described_class.perform_now
    described_class.perform_now(**continuations.shift)

    expect(calls).to eq([ *projects.map(&:id), projects.first.id ])
    expect(continuations).to be_empty
  end

  # @spec EAGER-QUEUE-017
  it "defers a persistently failing project after one retry and advances the cycle" do
    stub_const("AutoPickEligibilitySweepJob::PROJECT_PAGE_SIZE", 2)
    failing_project = create(:project, account:, created_by: owner, auto_pick_enabled: true)
    healthy_project = create(:project, account:, created_by: owner, auto_pick_enabled: true)
    later_project = create(:project, account:, created_by: owner, auto_pick_enabled: true)
    continuations = []
    calls = []
    allow(described_class).to receive(:perform_later) { |**arguments| continuations << arguments }
    allow(Issues::BulkEnqueueEligible).to receive(:call) do |project:, **|
      calls << project.id
      raise "queue unavailable" if project == failing_project

      page_result
    end

    described_class.perform_now
    described_class.perform_now(**continuations.shift)
    described_class.perform_now(**continuations.shift)

    expect(calls).to eq([ failing_project.id, healthy_project.id, failing_project.id, later_project.id ])
    expect(continuations).to be_empty
  end
end
