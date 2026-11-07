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
      failing_project.id => hash_including(project_id: failing_project.id, after_issue_id: nil)
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
  end
end
