# frozen_string_literal: true

require "rails_helper"

# @spec BOUNDED-DELEGATED-ACTION-001 @spec BOUNDED-DELEGATED-ACTION-002
RSpec.describe Automation::AuthorizeBoundedAction do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }
  let(:issue) { create(:issue, project:) }
  let(:user) { create(:user, :member, account:) }
  let(:evidence) { { "intent_digest" => "sha256:abc", "acceptance_refs" => [ "AC-1" ] } }

  it "creates a bounded action with inspectable evidence and audit" do
    action = described_class.call(project:, issue:, user:, action: "repair", evidence:)

    expect(action).to be_persisted
    expect(action.evidence).to eq(evidence)
    expect(account.account_activity_events.by_action("bounded_action.authorized").last).to have_attributes(
      actor: user,
      subject: action
    )
  end

  it "uses action-specific permission for merge" do
    expect {
      described_class.call(project:, issue:, user:, action: "merge", evidence:)
    }.to raise_error(Automation::AuthorizeBoundedAction::PermissionDenied)
  end

  it "never authorizes reserved product or release decisions" do
    expect {
      described_class.call(project:, issue:, user:, action: "product_decision", evidence:)
    }.to raise_error(Automation::AuthorizeBoundedAction::ProhibitedAction)
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
end
