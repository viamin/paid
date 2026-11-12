# frozen_string_literal: true

require "rails_helper"

RSpec.describe Automation::DelegatedActionAdmission do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) { create(:project, :with_github_installation, account: account, created_by: user) }
  let(:issue) { create(:issue, project: project) }
  let(:pull_request) do
    create(:issue, :pull_request, project: project, github_number: 42, parent_issue_id: issue.id)
  end

  before do
    FeatureFlags.enable!(:automation_phases, project:)
    FeatureFlags.enable!(:project_delegation, project:)
    project.update!(automation_phase_settings: {
      "phases" => { "coding" => true, "merge" => true }
    })
    create(:project_delegation_posture, project:, level: "bounded_delivery", revision: 1, selected_by: user)

    # Delegated work requires a current recorded assessment so rechecks are
    # otherwise current.
    [ issue, pull_request ].each do |work_item|
      assessment_run = create(:agent_run, :completed, project: project, issue: work_item)
      assessment_run.update!(reconciliation: { "assessment" => PartialCloseouts::Assessment.snapshot(
        assessment_run, { "criteria" => [], "gaps" => [] }
      ) })
    end
  end

  def authorize(action:, work_item: issue, stop_before_phase: "merge")
    create(:bounded_delegated_action,
      project: work_item.project,
      issue: work_item,
      action: action,
      evidence: described_class.admission_evidence(
        work_item: work_item, action: action, acceptance_refs: [ "AC-1" ], stop_before_phase: stop_before_phase
      ))
  end

  def recheck(goal: nil, action: nil, boundary: :dequeue, work_item: issue, trigger: :automatic,
    pull_request_number: nil)
    described_class.call(
      project: project,
      issue: work_item,
      pull_request_number: pull_request_number,
      goal: goal,
      action: action,
      boundary: boundary,
      trigger: trigger
    )
  end

  it "permits delegated work whose authorization is current at every fact" do # @spec PROJECT-DELEGATION-004
    authorize(action: "review")

    expect(recheck(goal: "review")).to be_permitted
    expect(Notification.count).to eq(0)
  end

  it "fails closed and records a security pause while no canonical security assessment is available" do # @spec PROJECT-DELEGATION-007
    FeatureFlags.enable!(:project_delegation_expansion, project:)
    authorize(action: "review")

    result = recheck(goal: "review")

    expect(result).to be_blocked
    expect(result.reasons).to include(:security)
    expect(InboxHistoryEvent.where(source: "project_delegation_pilot").pluck(:result))
      .to include("security_breach")
  end

  it "loads the governing authorization under its lifecycle lock" do # @spec BOUNDED-PHASE-AUTHORIZATION-004
    authorize(action: "review")
    statements = []
    subscriber = lambda { |_name, _start, _finish, _id, payload| statements << payload[:sql] }

    result = ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
      recheck(goal: "review")
    end

    expect(result).to be_permitted
    expect(statements).to include(match(/bounded_delegated_actions.*FOR UPDATE/i))
  end

  it "builds the closeout assessment once per boundary recheck" do # @spec PROJECT-DELEGATION-004
    authorize(action: "review")
    statements = []
    subscriber = lambda { |_name, _start, _finish, _id, payload| statements << payload[:sql] }

    result = ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
      recheck(goal: "review")
    end

    assessment_queries = statements.grep(/agent_runs.*reconciliation.*assessment/i)
    expect(result).to be_permitted
    expect(assessment_queries.size).to eq(1)
  end

  it "returns nil for work with no bounded authorization" do # @spec PROJECT-DELEGATION-004
    expect(recheck(goal: "review")).to be_nil
  end

  it "fails closed for a legacy authorization without canonical admission evidence" do # @spec BOUNDED-PHASE-AUTHORIZATION-004
    create(:bounded_delegated_action, project:, issue:, action: "review")

    result = recheck(goal: "review")

    expect(result).to be_blocked
    expect(result.reasons).to include(
      :intent_revision,
      :acceptance_revision,
      :evidence_revision,
      :posture_signature,
      :phase,
      :bounded_stop
    )
  end

  it "returns nil for goals with no delegable bounded action" do
    authorize(action: "review")

    expect(recheck(goal: "create_pr")).to be_nil
  end

  it "permits a delegated manual request when its phase is disabled" do # @spec PROJECT-DELEGATION-004 AUTOMATION-PHASES-003
    FeatureFlags.enable!(:automation_phases, project: project)
    project.update!(automation_phase_settings: {
      "phases" => { "coding" => false },
      "release" => false,
      "deployment" => false
    })
    authorize(action: "review")

    expect(recheck(goal: "review", trigger: :manual)).to be_permitted
  end

  it "resolves the PR work item for PR-scoped delegated runs" do
    authorize(action: "review", work_item: pull_request)

    result = recheck(work_item: nil, goal: "review", pull_request_number: 42)

    expect(result).to be_permitted
  end

  it "blocks and routes a focused decision when the authorization was revoked" do # @spec PROJECT-DELEGATION-004 BOUNDED-PHASE-AUTHORIZATION-004
    authorization = authorize(action: "review")
    authorization.update!(status: "revoked")

    result = recheck(goal: "review")

    expect(result).to be_blocked
    expect(result.reasons).to include(:authorization_lifecycle)
    notification = Notification.find_by(source: Automation::DelegatedWorkBoundary::NOTIFICATION_SOURCE)
    expect(notification).to be_blocking
    expect(notification.metadata).to include("boundary" => "dequeue", "reasons" => array_including("authorization_lifecycle"))
  end

  it "lets a newer explicit authorization supersede a revoked one" do
    stale = authorize(action: "review")
    stale.update!(status: "revoked")
    authorize(action: "review")

    expect(recheck(goal: "review")).to be_permitted
  end

  it "blocks when the work item's intent changed since admission" do # @spec PROJECT-DELEGATION-004
    authorize(action: "review")
    issue.update!(title: "A materially different request")

    result = recheck(goal: "review")

    expect(result).to be_blocked
    expect(result.reasons).to include(:intent_revision)
  end

  it "blocks an explicit work-item hold at the shared admission boundary" do # @spec PROJECT-DELEGATION-006 BOUNDED-PHASE-AUTHORIZATION-005
    authorize(action: "review")
    issue.update!(hold_for_review: true)

    result = recheck(goal: "review")

    expect(result).to be_blocked
    expect(result.reasons).to include(:explicit_hold)
  end

  it "blocks when the project posture narrows after admission" do # @spec PROJECT-DELEGATION-006
    authorize(action: "review")
    project.delegation_posture.update!(
      level: "conservative",
      revision: 2,
      enabled_action_classes: [],
      policy_signature: ProjectDelegation::Posture.policy_signature(project)
    )

    result = recheck(goal: "review")

    expect(result).to be_blocked
    expect(result.reasons).to include(:posture_signature, :phase_policy)
  end

  it "blocks when a rollout guard rolls a bounded posture back" do # @spec PROJECT-DELEGATION-006
    authorize(action: "review")
    FeatureFlags.disable!(:project_delegation, project:)

    result = recheck(goal: "review")

    expect(result).to be_blocked
    expect(result.reasons).to include(:posture_signature, :phase_policy)
  end

  it "applies the shared effective policy to delegated repair boundaries" do # @spec PROJECT-DELEGATION-005
    FeatureFlags.enable!(:automation_phases, project: project)
    project.update!(automation_phase_settings: {
      "phases" => { "coding" => false },
      "release" => false,
      "deployment" => false
    })
    authorize(action: "repair")

    result = recheck(goal: "layered_verification_repair", boundary: :repair)

    expect(result).to be_blocked
    expect(result.reasons).to include(:phase_policy)
  end

  it "blocks when a hard-stop budget is exceeded" do # @spec PROJECT-DELEGATION-004
    authorize(action: "review")
    create(:cost_budget, project: project, budget_type: "monthly", limit_cents: 100,
      current_usage_cents: 500, enforcement_mode: "hard_stop")

    result = recheck(goal: "review")

    expect(result).to be_blocked
    expect(result.reasons).to include(:budget)
  end

  it "blocks when the repository-control channel is inactive" do # @spec PROJECT-DELEGATION-004
    authorize(action: "review")
    project.github_installation.update!(revoked_at: Time.current)

    result = recheck(goal: "review")

    expect(result).to be_blocked
    expect(result.reasons).to include(:repository_controls)
  end

  it "blocks when the repository-control channel is absent" do # @spec PROJECT-DELEGATION-004
    pat_project = create(:project, account: account, created_by: user)
    pat_issue = create(:issue, project: pat_project)
    authorize(action: "review", work_item: pat_issue)

    result = described_class.call(project: pat_project, issue: pat_issue, goal: "review", boundary: :dequeue)

    expect(result).to be_blocked
    expect(result.reasons).to include(:repository_controls)
  end

  it "blocks when no current assessment is recorded for the work item" do # @spec PROJECT-DELEGATION-004
    authorize(action: "review")
    issue.agent_runs.update_all(reconciliation: {})

    result = recheck(goal: "review")

    expect(result).to be_blocked
    expect(result.reasons).to include(:assessment_availability)
  end

  it "checks merge execution at the closeout boundary against the merge stop" do # @spec PROJECT-DELEGATION-004
    authorize(action: "merge", work_item: pull_request, stop_before_phase: "release_deployment")

    expect(recheck(action: "merge", boundary: :closeout, work_item: pull_request)).to be_permitted
  end
end
