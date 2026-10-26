# frozen_string_literal: true

require "rails_helper"

RSpec.describe Dashboard::QueueDiagnosis do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) { create(:project, account: account, created_by: user, auto_pick_enabled: true) }

  def breakdown(eligible: 0, skip_label: 0, needs_input: 0, manual_review: 0, other_excluded: 0)
    Dashboard::EligibilityBreakdown::ProjectBreakdown.new(
      project: project,
      total_open: eligible + skip_label + needs_input + manual_review + other_excluded,
      eligible: eligible,
      needs_input: needs_input,
      skip_label: skip_label,
      completed: 0,
      in_progress: 0,
      manual_review: manual_review,
      other_excluded: other_excluded
    )
  end

  # @spec AUTO-PICK-QUEUE-014
  it "distinguishes eligible work that was not seeded from queued or active work" do
    diagnosis = described_class.call(user: user, breakdowns: [ breakdown(eligible: 2) ])

    expect(diagnosis).to have_attributes(
      state: :runnable_unseeded,
      eligible_count: 2,
      queued_count: 0,
      active_count: 0,
      action: :wait_for_auto_pick_sweep
    )
  end

  # @spec AUTO-PICK-QUEUE-014
  it "recognizes active work without a waiting backlog as healthy" do
    create(:agent_run, project: project, status: "running")

    diagnosis = described_class.call(user: user, breakdowns: [ breakdown ])

    expect(diagnosis).to have_attributes(
      state: :healthy_active_work,
      eligible_count: 0,
      queued_count: 0,
      active_count: 1,
      action: :none
    )
  end

  # @spec AUTO-PICK-QUEUE-014
  it "reports explicit exclusion counts as ordinary holds" do
    diagnosis = described_class.call(user: user, breakdowns: [ breakdown(skip_label: 3, needs_input: 1) ])

    expect(diagnosis).to have_attributes(
      state: :held,
      held_count: 4,
      action: :review_eligibility
    )
  end

  # @spec AUTO-PICK-QUEUE-014
  it "recognizes a deliberate quality pause without calling recovery" do
    diagnosis = described_class.call(user: user, breakdowns: [], paused_projects: [ project ])

    expect(diagnosis).to have_attributes(state: :paused, action: :review_eligibility)
  end

  # @spec AUTO-PICK-QUEUE-014
  it "reports failed eligibility coverage as unknown rather than no work" do
    allow(Dashboard::EligibilityBreakdown).to receive(:call).and_raise(ActiveRecord::ConnectionNotEstablished)

    diagnosis = described_class.call(user: user)

    expect(diagnosis).to have_attributes(state: :unknown, action: :refresh)
  end
end
