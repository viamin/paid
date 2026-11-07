# frozen_string_literal: true

require "rails_helper"

# The one shared delegation read model: settings, Inbox, API, and MCP read
# delegation state through this projection and Automation::EffectivePolicy
# instead of inferring authority locally.
# @spec PROJECT-DELEGATION-005
RSpec.describe ProjectDelegation::Projection do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) { create(:project, :with_github_installation, account: account, created_by: user) }
  let(:issue) { create(:issue, project: project) }

  before do
    FeatureFlags.enable!(:automation_phases, project:)
  end

  def authorize_review(work_item: issue, stop_before_phase: "merge")
    create(:bounded_delegated_action,
      project: project,
      issue: work_item,
      action: "review",
      evidence: Automation::DelegatedActionAdmission.admission_evidence(
        work_item: work_item, action: "review", acceptance_refs: [ "AC-1" ], stop_before_phase: stop_before_phase
      ))
  end

  def disable_delivery_phases
    project.update!(
      Automation::PhaseSettings::SETTINGS_KEY => {
        Automation::PhaseSettings::PHASES_KEY => { "coding" => false, "merge" => false },
        Automation::PhaseSettings::RELEASE_KEY => false,
        Automation::PhaseSettings::DEPLOYMENT_KEY => false
      }
    )
  end

  it "projects the latest bounded authorization per action with its lifecycle state" do
    authorization = authorize_review

    state = described_class.for_work_item(project: project, work_item: issue).authorization_for("review")

    expect(state).to have_attributes(
      id: authorization.id,
      action: "review",
      phase: Automation::Phases::CODING,
      stop_before_phase: "merge",
      status: "active"
    )
    expect(state).to be_in_force
  end

  it "reports an expired authorization as not in force" do
    authorization = authorize_review
    authorization.update!(expires_at: 1.minute.ago)

    state = described_class.for_work_item(project: project, work_item: issue).authorization_for("review")

    expect(state).not_to be_in_force
    expect(state).to be_expired
  end

  it "keeps only the newest authorization for an action as governing" do
    stale = authorize_review
    stale.update!(status: "revoked")
    fresh = authorize_review

    state = described_class.for_work_item(project: project, work_item: issue).authorization_for("review")

    expect(state.id).to eq(fresh.id)
    expect(state).to be_in_force
  end

  it "answers phase authority through Automation::EffectivePolicy, not local inference" do
    disable_delivery_phases
    projection = described_class.for_work_item(project: project, work_item: issue)

    expect(projection.phase_decision("coding")).to be_blocked

    create(:work_item_continuation_grant, project: project, issue: issue, start_phase: "coding", endpoint: "merge")
    decision = described_class.for_work_item(project: project, work_item: issue).phase_decision("coding")

    expect(decision).to be_permitted
    expect(decision.source).to eq(:continuation_grant)
  end

  it "exposes the same posture signature the admission contract pins" do
    projection = described_class.for_work_item(project: project, work_item: issue)

    expect(projection.posture_signature(action: "review")).to eq(
      Automation::DelegatedActionAdmission.posture_signature_for(project: project, action: "review")
    )
  end

  it "signs the projected state so surfaces can detect change" do
    projection = described_class.for_work_item(project: project, work_item: issue)
    first_signature = projection.signature

    expect(projection.to_h.fetch(:signature)).to eq(first_signature)

    authorize_review
    refreshed = described_class.for_work_item(project: project, work_item: issue)

    expect(refreshed.signature).not_to eq(first_signature)
  end

  it "scopes a project projection to the newest authorization per work item and action" do
    other_issue = create(:issue, project: project)
    authorize_review
    authorize_review(work_item: other_issue)

    states = described_class.for_project(project).authorizations

    expect(states.map(&:work_item_id)).to contain_exactly(issue.id, other_issue.id)
    expect(states).to all(have_attributes(action: "review", in_force?: true))
  end

  it "serializes one payload for the API and MCP surfaces" do
    authorize_review

    payload = described_class.for_project(project).to_h

    expect(payload).to include(
      project_id: project.id,
      authorizations: [ hash_including(action: "review", in_force: true, stop_before_phase: "merge") ]
    )
    expect(payload.fetch(:phase_authority).fetch("review")).to include(permitted: true)
    expect(payload).to include(:signature)
  end

  it "projects an agent-run work item through its issue" do
    run = create(:agent_run, project: project, issue: issue)
    authorization = authorize_review

    state = described_class.for_work_item(project: project, work_item: run).authorization_for("review")

    expect(state.id).to eq(authorization.id)
  end

  it "exposes continuation grants through the shared chain lookup" do
    grant = create(:work_item_continuation_grant, project: project, issue: issue,
      start_phase: "coding", endpoint: "merge")

    grants = described_class.for_work_item(project: project, work_item: issue).continuation_grants("merge")

    expect(grants.map(&:id)).to eq([ grant.id ])
  end
end
