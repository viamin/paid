# frozen_string_literal: true

require "rails_helper"

# The authorized project-delegation posture write path (RDR-080): only an
# owner or project admin may select a posture, broadening requires both
# rollout guards, every selection bumps the revision, and each selection
# records an immutable audit event naming the actor, project, revision, and
# enabled action classes.
# @spec PROJECT-DELEGATION-001
RSpec.describe ProjectDelegation::SelectPosture do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account: account) }
  let(:project) { create(:project, :with_github_installation, account: account, created_by: owner) }

  before do
    FeatureFlags.enable!(:automation_phases, project:)
    FeatureFlags.enable!(:project_delegation, project:)
  end

  def audit_events
    AccountActivityEvent.where(action: "project_delegation.posture_selected", subject: project)
  end

  it "records a bounded_delivery selection with revision, action classes, and policy signature" do
    posture = described_class.call(project: project, actor: owner, level: "bounded_delivery")

    record = project.delegation_posture
    expect(record).to have_attributes(
      level: "bounded_delivery",
      revision: 1,
      enabled_action_classes: ProjectDelegation::Posture::DELEGATED_ACTION_CLASSES,
      selected_by: owner,
      account: account
    )
    expect(record.policy_signature).to eq(ProjectDelegation::Posture.policy_signature(project))
    expect(posture).to be_bounded_delivery
    expect(posture.revision).to eq(1)
  end

  it "records an immutable audit event naming actor, project, revision, and action classes" do
    described_class.call(project: project, actor: owner, level: "bounded_delivery")

    expect(audit_events.count).to eq(1)
    event = audit_events.last
    expect(event).to have_attributes(actor: owner, account: account)
    expect(event.metadata).to include(
      "level" => "bounded_delivery",
      "previous_level" => "conservative",
      "revision" => 1,
      "enabled_action_classes" => ProjectDelegation::Posture::DELEGATED_ACTION_CLASSES,
      "project_id" => project.id
    )
  end

  it "increments the revision on every selection" do
    described_class.call(project: project, actor: owner, level: "bounded_delivery")
    described_class.call(project: project, actor: owner, level: "conservative")

    record = project.delegation_posture.reload
    expect(record).to have_attributes(level: "conservative", revision: 2)
    expect(audit_events.order(:id).last.metadata).to include(
      "level" => "conservative", "previous_level" => "bounded_delivery", "revision" => 2
    )
  end

  it "lets an account admin select the posture" do
    admin = create(:user, :admin, account: account)

    expect(described_class.call(project: project, actor: admin, level: "bounded_delivery")).to be_bounded_delivery
  end

  it "lets a project admin select the posture" do
    project_admin = create(:user, account: account)
    project_admin.add_role(:project_admin, project)

    expect(described_class.call(project: project, actor: project_admin, level: "bounded_delivery")).to be_bounded_delivery
  end

  it "rejects a plain account member and records nothing" do
    member = create(:user, :member, account: account)

    expect { described_class.call(project: project, actor: member, level: "bounded_delivery") }
      .to raise_error(ProjectDelegation::SelectPosture::PermissionDenied)

    expect(project.delegation_posture).to be_nil
    expect(audit_events).to be_empty
  end

  it "rejects an actor outside the project's account" do
    outsider = create(:user, :owner, account: create(:account))

    expect { described_class.call(project: project, actor: outsider, level: "bounded_delivery") }
      .to raise_error(ProjectDelegation::SelectPosture::PermissionDenied)
  end

  it "blocks broadening while the project_delegation guard is off" do
    FeatureFlags.disable!(:project_delegation, project:)

    expect { described_class.call(project: project, actor: owner, level: "bounded_delivery") }
      .to raise_error(ProjectDelegation::SelectPosture::GuardDisabled)

    expect(project.delegation_posture).to be_nil
    expect(audit_events).to be_empty
  end

  it "blocks broadening while the automation_phases rollout is off" do
    FeatureFlags.disable!(:automation_phases, project:)

    expect { described_class.call(project: project, actor: owner, level: "bounded_delivery") }
      .to raise_error(ProjectDelegation::SelectPosture::GuardDisabled)
  end

  it "still allows narrowing to conservative while the guards are off (rollback)" do
    described_class.call(project: project, actor: owner, level: "bounded_delivery")
    FeatureFlags.disable!(:project_delegation, project:)

    posture = described_class.call(project: project, actor: owner, level: "conservative")

    expect(posture).to be_conservative
    expect(project.delegation_posture.reload).to have_attributes(level: "conservative", revision: 2)
    expect(audit_events.count).to eq(2)
  end

  it "rejects an unknown posture level without recording anything" do
    expect { described_class.call(project: project, actor: owner, level: "autonomous") }
      .to raise_error(ProjectDelegation::SelectPosture::UnknownLevel)

    expect(project.delegation_posture).to be_nil
    expect(audit_events).to be_empty
  end
end
