# frozen_string_literal: true

require "rails_helper"

# @spec BOUNDED-PHASE-AUTHORIZATION-011
RSpec.describe Automation::RevokeBoundedAction do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }
  let(:issue) { create(:issue, project:) }
  let(:user) { create(:user, :member, account:) }

  it "revokes an active repair authorization and records the audit event" do
    authorization = create(:bounded_delegated_action, project:, issue:, created_by: user, action: "repair")

    expect(described_class.call(authorization:, user:)).to be(true)
    expect(authorization.reload).to be_revoked
    expect(account.account_activity_events.by_action("bounded_action.revoked").last).to have_attributes(
      actor: user,
      subject: authorization
    )
  end

  it "denies a plain member revocation of an owner-authorized merge delegation" do
    owner = create(:user, :owner, account:)
    authorization = create(:bounded_delegated_action, project:, issue:, created_by: owner, action: "merge")

    expect {
      described_class.call(authorization:, user:)
    }.to raise_error(Automation::RevokeBoundedAction::PermissionDenied, /merge/)
    expect(authorization.reload).to be_active
  end

  it "permits a project administrator to revoke a merge authorization" do
    admin = create(:user, :admin, account:)
    admin.add_role(:project_admin, project)
    authorization = create(:bounded_delegated_action, project:, issue:, created_by: admin, action: "merge")

    expect(described_class.call(authorization:, user: admin)).to be(true)
    expect(authorization.reload).to be_revoked
  end

  it "denies revocation by a user outside the account" do
    authorization = create(:bounded_delegated_action, project:, issue:, created_by: user)
    outsider = create(:user)

    expect {
      described_class.call(authorization:, user: outsider)
    }.to raise_error(Automation::RevokeBoundedAction::PermissionDenied)
    expect(authorization.reload).to be_active
  end

  it "leaves an already-revoked authorization untouched" do
    authorization = create(:bounded_delegated_action, project:, issue:, created_by: user)
    described_class.call(authorization:, user:)

    expect(described_class.call(authorization:, user:)).to be(false)
    expect(account.account_activity_events.by_action("bounded_action.revoked").count).to eq(1)
  end
end
