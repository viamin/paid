# frozen_string_literal: true

require "rails_helper"

# @spec BOUNDED-PHASE-AUTHORIZATION-010 @spec BOUNDED-PHASE-AUTHORIZATION-011
RSpec.describe Automation::AuthorizeBoundedAction do
  let(:account) { create(:account) }
  let(:project) { create(:project, :with_github_installation, account:, created_by: user) }
  let(:issue) { create(:issue, project:) }
  let(:user) { create(:user, :member, account:) }
  let(:intent_digest) { "sha256:#{PartialCloseouts::Assessment.intent_revision_for(issue)}" }
  let(:evidence) do
    {
      "intent_digest" => intent_digest,
      "acceptance_refs" => [ "AC-1" ],
      "stop_before_phase" => "merge"
    }
  end

  it "creates a bounded action with inspectable evidence and audit" do
    action = described_class.call(project:, issue:, user:, action: "repair", evidence:)

    expect(action).to be_persisted
    expect(action.evidence).to include(
      "acceptance_refs" => [ "AC-1" ],
      "phase" => "coding",
      "stop_before_phase" => "merge"
    )
    expect(action.evidence).to include(*Automation::DelegatedActionAdmission.revision_tokens(issue:).keys)
    expect(action.evidence["posture_signature"]).to be_present
    expect(account.account_activity_events.by_action("bounded_action.authorized").last).to have_attributes(
      actor: user,
      subject: action
    )
  end

  it "persists canonical evidence that passes the delegated-work boundary" do # @spec BOUNDED-PHASE-AUTHORIZATION-004 PROJECT-DELEGATION-004
    FeatureFlags.enable!(:automation_phases, project:)
    FeatureFlags.enable!(:project_delegation, project:)
    create(:project_delegation_posture, project: project)
    assessment_run = create(:agent_run, :completed, project:, issue:)
    assessment_run.update!(reconciliation: { "assessment" => PartialCloseouts::Assessment.snapshot(
      assessment_run, { "criteria" => [], "gaps" => [] }
    ) })

    authorization = described_class.call(project:, issue:, user:, action: "repair", evidence:)
    result = Automation::DelegatedActionAdmission.call(
      project:, issue:, action: "repair", boundary: :create
    )

    expect(authorization.evidence).to eq(
      Automation::DelegatedActionAdmission.admission_evidence(
        work_item: issue,
        action: "repair",
        acceptance_refs: [ "AC-1" ],
        stop_before_phase: "merge"
      )
    )
    expect(result).to be_permitted
  end

  it "uses action-specific permission for merge" do
    expect {
      described_class.call(project:, issue:, user:, action: "merge", evidence:)
    }.to raise_error(Automation::AuthorizeBoundedAction::PermissionDenied)
  end

  it "permits merge delegation for a project administrator" do
    user.add_role(:project_admin, project)

    action = described_class.call(
      project:, issue:, user:, action: "merge", evidence: evidence.merge("stop_before_phase" => "release_deployment")
    )

    expect(action).to be_persisted
    expect(action.action).to eq("merge")
  end

  it "never authorizes reserved product or release decisions" do
    expect {
      described_class.call(project:, issue:, user:, action: "product_decision", evidence:)
    }.to raise_error(Automation::AuthorizeBoundedAction::ProhibitedAction, /reserved decision/)
  end

  it "rejects an issue from another project" do
    other_project = create(:project, account:)
    other_issue = create(:issue, project: other_project)

    expect {
      described_class.call(project:, issue: other_issue, user:, action: "repair", evidence:)
    }.to raise_error(Automation::AuthorizeBoundedAction::InvalidScope)
  end

  it "rejects evidence that is not an object" do
    expect {
      described_class.call(project:, issue:, user:, action: "repair", evidence: nil)
    }.to raise_error(Automation::AuthorizeBoundedAction::InvalidEvidence)
  end

  it "rejects evidence without an intent digest with a typed domain error" do
    expect {
      described_class.call(project:, issue:, user:, action: "repair", evidence: { "acceptance_refs" => [ "AC-1" ] })
    }.to raise_error(Automation::AuthorizeBoundedAction::InvalidEvidence, /intent_digest/)
  end

  it "rejects a truthy intent digest that is not a sha256 digest" do
    expect {
      described_class.call(project:, issue:, user:, action: "repair",
        evidence: { intent_digest: true, acceptance_refs: [ "AC-1" ] })
    }.to raise_error(Automation::AuthorizeBoundedAction::InvalidEvidence, /intent_digest/)
  end

  it "rejects an intent digest with a malformed sha256 form" do
    expect {
      described_class.call(project:, issue:, user:, action: "repair",
        evidence: { "intent_digest" => "sha256:abc", "acceptance_refs" => [ "AC-1" ] })
    }.to raise_error(Automation::AuthorizeBoundedAction::InvalidEvidence, /intent_digest/)
  end

  it "rejects a well-formed digest for stale intent" do
    stale_digest = "sha256:#{Digest::SHA256.hexdigest('stale intent')}"

    expect {
      described_class.call(project:, issue:, user:, action: "repair",
        evidence: evidence.merge("intent_digest" => stale_digest))
    }.to raise_error(Automation::AuthorizeBoundedAction::InvalidEvidence, /current intent/)
  end

  it "rejects evidence without acceptance references with a typed domain error" do
    expect {
      described_class.call(project:, issue:, user:, action: "repair", evidence: { "intent_digest" => intent_digest })
    }.to raise_error(Automation::AuthorizeBoundedAction::InvalidEvidence, /acceptance_refs/)
  end

  it "rejects evidence without a bounded stop" do
    expect {
      described_class.call(project:, issue:, user:, action: "repair",
        evidence: evidence.except("stop_before_phase"))
    }.to raise_error(Automation::AuthorizeBoundedAction::InvalidEvidence, /stop_before_phase/)
  end

  it "rejects a bounded stop that does not match the delegated action" do
    expect {
      described_class.call(project:, issue:, user:, action: "repair",
        evidence: evidence.merge("stop_before_phase" => "release_deployment"))
    }.to raise_error(Automation::AuthorizeBoundedAction::InvalidEvidence, /must be merge for repair/)
  end
end
