# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issues::AutoResolveCloseout do
  let(:account) { create(:account) }
  let(:owner) { create(:user, account:) }
  let(:project) { create(:project, :with_github_installation, account:, created_by: owner, owner: "acme", repo: "alpha", auto_merge_mode: "all") }
  let(:issue) { create(:issue, project:, github_state: "open") }
  let(:client) { instance_double(GithubClient) }

  before do
    FeatureFlags.enable!(:automation_phases, project:)
    FeatureFlags.enable!(:project_delegation, project:)
    allow(project).to receive(:client).and_return(client)
    allow(client).to receive_messages(issue: Struct.new(:state).new("open"), update_issue: Struct.new(:state).new("closed"))
  end

  def audit_run(captured_signature: nil)
    create(:issue, :pull_request, project:, parent_issue_id: issue.id, github_state: "closed",
      pr_review_phase: "merged", github_number: 1234)
    request = create(:issue_continuation_request, :consumed, issue:, project:, requested_by: owner,
      evidence: { "continuation_mode" => "acceptance_audit", "closeout_policy_signature" => captured_signature,
        "source_revision" => PartialCloseouts::Assessment.source_revision_for(issue),
        "intent_revision" => PartialCloseouts::Assessment.intent_revision_for(issue) })
    run = create(:agent_run, :completed, project:, issue:, goal: "analyze_issue", continuation_request: request)
    run.update!(reconciliation: { "assessment" => PartialCloseouts::Assessment.snapshot(run,
      { "criteria" => [ { "criterion" => "Delivered feature", "state" => "satisfied" } ], "gaps" => [] }) })
    run
  end

  def authorize_closeout
    create(:project_delegation_posture, project:, selected_by: owner)
    Automation::DelegatedActionAdmission.posture_signature_for(project:, action: "issue_closure")
  end

  # @spec PROJECT-DELEGATION-009
  it "closes only a fully accepted issue whose audit captured current delegated authority" do
    run = audit_run(captured_signature: authorize_closeout)

    result = described_class.call(agent_run: run, client:)

    expect(result).to eq(:closed)
    expect(issue.reload.github_state).to eq("closed")
    expect(issue.closeout_resolved_by).to be_nil
    expect(client).to have_received(:update_issue).once
    event = account.account_activity_events.find_by!(action: "issue.closeout_resolved", subject: issue)
    expect(event.actor).to be_nil
    expect(event.metadata).to include("initiator" => "delegated_acceptance_audit", "agent_run_id" => run.id,
      "assessment_source_revision" => run.reconciliation.dig("assessment", "source_revision"))
    expect(account.account_activity_events.find_by!(action: "issue.auto_closeout_attempted", subject: issue).metadata)
      .to include("result" => "closed", "agent_run_id" => run.id)
  end

  # @spec PROJECT-DELEGATION-009
  it "does not close a conservative project's issue" do
    run = audit_run

    expect(described_class.call(agent_run: run, client:)).to eq(:not_delegated)
    expect(issue.reload.github_state).to eq("open")
    expect(client).not_to have_received(:update_issue)
  end

  # @spec PROJECT-DELEGATION-009
  it "does not let a policy change broaden or preserve stale audit authority" do
    run = audit_run
    authorize_closeout

    expect(described_class.call(agent_run: run, client:)).to eq(:not_delegated)
    expect(issue.reload.github_state).to eq("open")
  end

  # @spec PROJECT-DELEGATION-009
  it "does not close from a stale assessment after intent changes" do
    run = audit_run(captured_signature: authorize_closeout)
    issue.update!(title: "Revised intent")

    expect(described_class.call(agent_run: run, client:)).to eq(:not_delegated)
    expect(issue.reload.github_state).to eq("open")
    expect(client).not_to have_received(:update_issue)
  end

  # @spec PROJECT-DELEGATION-009
  it "does not close an audit with an unknown criterion" do
    run = audit_run(captured_signature: authorize_closeout)
    run.update!(reconciliation: { "assessment" => PartialCloseouts::Assessment.snapshot(run,
      { "criteria" => [ { "criterion" => "Delivered feature", "state" => "unknown" } ], "gaps" => [] }) })

    expect(described_class.call(agent_run: run, client:)).to eq(:blocked)
    expect(issue.reload.github_state).to eq("open")
    expect(client).not_to have_received(:update_issue)
  end

  # @spec PROJECT-DELEGATION-009
  it "does not close when the delegated posture is revoked after audit admission" do
    run = audit_run(captured_signature: authorize_closeout)
    project.delegation_posture.update!(level: "conservative", revision: 2, enabled_action_classes: [])

    expect(described_class.call(agent_run: run, client:)).to eq(:not_delegated)
    expect(issue.reload.github_state).to eq("open")
  end

  # @spec PROJECT-DELEGATION-009
  it "leaves an issue with an open prerequisite visible" do
    run = audit_run(captured_signature: authorize_closeout)
    prerequisite = create(:issue, project:, github_state: "open")
    create(:issue_dependency, issue:, depends_on_issue: prerequisite)

    expect(described_class.call(agent_run: run, client:)).to eq(:blocked)
    expect(issue.reload.github_state).to eq("open")
    expect(client).not_to have_received(:update_issue)
  end

  # @spec PROJECT-DELEGATION-009
  it "retains the issue when GitHub closure fails" do
    run = audit_run(captured_signature: authorize_closeout)
    allow(client).to receive(:update_issue).and_raise(GithubClient::Error, "unavailable")

    expect(described_class.call(agent_run: run, client:)).to eq(:github_failed)
    expect(issue.reload.github_state).to eq("open")
    expect(account.account_activity_events.find_by!(action: "issue.auto_closeout_attempted", subject: issue).metadata)
      .to include("result" => "github_failed")
  end

  # @spec PROJECT-DELEGATION-009
  it "rechecks delegation after the remote read and before the GitHub write" do
    run = audit_run(captured_signature: authorize_closeout)
    allow(client).to receive(:issue) do
      project.delegation_posture.update!(level: "conservative", revision: 2, enabled_action_classes: [])
      Struct.new(:state).new("open")
    end

    expect(described_class.call(agent_run: run, client:)).to eq(:authorization_changed)
    expect(issue.reload.github_state).to eq("open")
    expect(client).not_to have_received(:update_issue)
  end
end
