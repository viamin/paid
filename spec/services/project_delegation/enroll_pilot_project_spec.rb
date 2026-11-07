# frozen_string_literal: true

require "rails_helper"

# @spec PROJECT-DELEGATION-007
RSpec.describe ProjectDelegation::EnrollPilotProject do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }
  let(:owner) { create(:user, :owner, account:) }

  before do
    FeatureFlags.enable!(:automation_phases, project:)
    FeatureFlags.enable!(:project_delegation, project:)
  end

  def enroll(target = project)
    described_class.call(project: target, actor: owner)
  end

  def enroll_new_project
    other = create(:project, account:)
    FeatureFlags.enable!(:automation_phases, project: other)
    FeatureFlags.enable!(:project_delegation, project: other)
    enroll(other)
  end

  it "opts a project in and captures its own conservative baseline" do
    issue = create(:issue, project:, paid_state: "completed")

    result = enroll

    expect(result).to be_success
    enrollment = result.enrollment
    expect(enrollment.project).to eq(project)
    expect(enrollment.posture).to eq("bounded_delivery")
    expect(enrollment).to be_active
    expect(enrollment.enrolled_at).to be_within(1.second).of(Time.current)

    baseline = enrollment.snapshots.conservative_baseline.first
    expect(baseline).to be_present
    expect(baseline.window_ended_at).to be_within(1.second).of(enrollment.enrolled_at)
    expect(baseline.window_started_at).to be_within(1.second).of(
      enrollment.enrolled_at - described_class::BASELINE_WINDOW_DAYS.days
    )
    expect(baseline.metrics["completed_issues"]).to eq(1)

    expect(account.account_activity_events.by_action("delegation_pilot.enrolled").last).to have_attributes(
      actor: owner,
      subject: enrollment
    )
  end

  it "refuses enrollment while the rollout guards are off" do
    FeatureFlags.enable!(:automation_phases, project:)
    FeatureFlags.disable!(:project_delegation, project:)

    result = enroll

    expect(result).not_to be_success
    expect(result.error).to eq("broadening is disabled while the project_delegation guard is off")
    expect(DelegationPilotEnrollment).not_to exist
  end

  it "refuses enrollment while the automation_phases guard is off" do
    FeatureFlags.disable!(:automation_phases, project:)
    FeatureFlags.enable!(:project_delegation, project:)

    result = enroll

    expect(result).not_to be_success
    expect(result.error).to eq("broadening is disabled while the automation_phases guard is off")
    expect(DelegationPilotEnrollment).not_to exist
  end

  it "refuses a duplicate enrollment" do
    enroll

    result = enroll

    expect(result).not_to be_success
    expect(result.error).to eq("project is already enrolled in the delegation pilot")
    expect(project.delegation_pilot_enrollments.count).to eq(1)
  end

  it "caps the pilot at five concurrently active projects" do
    5.times { enroll_new_project }

    result = enroll

    expect(result).not_to be_success
    expect(result.error).to eq("the delegation pilot is limited to 5 active projects")
    expect(DelegationPilotEnrollment.active.count).to eq(5)
  end

  it "counts only active enrollments toward the pilot cap" do
    5.times { enroll_new_project }
    DelegationPilotEnrollment.update_all(status: "paused")

    expect(enroll).to be_success
  end
end
