# frozen_string_literal: true

require "rails_helper"

# @spec PARTIAL-CLOSEOUT-063
RSpec.describe Tools::ManageSharedDeliveryEvidence do
  let(:account) { create(:account) }
  let(:actor) { create(:user, :member, account:) }
  let(:project) { create(:project, account:, owner: "acme", repo: "alpha") }
  let(:session) { create(:chat_session, account:, created_by: actor, project:) }
  let(:issue) { create(:issue, project:) }
  let(:pull_request) do
    create(:issue, :pull_request, project:, github_number: 5371, pr_review_phase: "merged",
      github_state: "closed", github_html_url: "https://github.com/acme/alpha/pull/5371",
      merged_commit_sha: "a" * 40)
  end

  it "requires confirmation to associate and revoke shared evidence" do
    tool = described_class.new(user: actor, session:)

    expect {
      tool.call(project_id: project.id, issue_id: issue.id, pull_request_id: pull_request.id,
        action: "associate", confirmed: false)
    }.to raise_error(ArgumentError, /Confirmation required/)

    result = tool.call(project_id: project.id, issue_id: issue.id,
      pull_request_id: pull_request.id, action: "associate", confirmed: true)
    expect(result).to include(active: true, revision: "a" * 40)

    revoked = tool.call(project_id: project.id, issue_id: issue.id,
      action: "revoke", confirmed: true)
    expect(revoked).to include(active: false)
  end

  it "denies a same-account viewer without persisting authorization" do
    viewer = create(:user, :viewer, account:)
    viewer_session = create(:chat_session, account:, created_by: viewer, project:)

    expect {
      described_class.new(user: viewer, session: viewer_session).call(
        project_id: project.id, issue_id: issue.id, pull_request_id: pull_request.id,
        action: "associate", confirmed: true)
    }.to raise_error(Pundit::NotAuthorizedError)
    expect(SharedDeliveryEvidenceAssociation.where(issue:)).to be_empty
  end

  it "revokes deleted-authorizer history and permits a separately authorized replacement" do # @spec PARTIAL-CLOSEOUT-064
    association = Issues::AssociateSharedDeliveryEvidence.call(issue:, pull_request:, actor:)
    operator = create(:user, :owner, account:)
    Accounts::RemoveMembership.call(account:, membership: actor.account_membership_for(account), actor: operator)
    historical = association.reload.attributes.except("revoked_at", "updated_at")
    operator_session = create(:chat_session, account:, created_by: operator, project:)
    tool = described_class.new(user: operator, session: operator_session)

    result = tool.call(project_id: project.id, issue_id: issue.id, action: "revoke", confirmed: true)

    expect(result).to include(id: association.id, active: false)
    expect(association.reload.attributes.except("revoked_at", "updated_at")).to eq(historical)
    expect(association).not_to be_current
    replacement = tool.call(project_id: project.id, issue_id: issue.id,
      pull_request_id: pull_request.id, action: "associate", confirmed: true)
    expect(replacement.fetch(:id)).not_to eq(association.id)
    expect(SharedDeliveryEvidenceAssociation.find(replacement.fetch(:id)))
      .to have_attributes(authorized_by_id: operator.id, revoked_at: nil)
    expect(association.reload.authorized_by_id).to be_nil
  end

  it "cannot resolve records from another project" do
    foreign_issue = create(:issue)

    expect {
      described_class.new(user: actor, session:).call(
        project_id: project.id, issue_id: foreign_issue.id,
        pull_request_id: pull_request.id, action: "associate", confirmed: true)
    }.to raise_error(ActiveRecord::RecordNotFound)
  end

  it "refuses a closed source issue without persisting an association" do
    closed_issue = create(:issue, :closed, project:)

    expect {
      described_class.new(user: actor, session:).call(
        project_id: project.id, issue_id: closed_issue.id, pull_request_id: pull_request.id,
        action: "associate", confirmed: true)
    }.to raise_error(ArgumentError, /open source issue/)
    expect(SharedDeliveryEvidenceAssociation.where(issue: closed_issue)).to be_empty
  end

  it "refuses a pull-request source at the service boundary" do
    pr_source = create(:issue, :pull_request, project:, github_state: "open")

    expect {
      Issues::AssociateSharedDeliveryEvidence.call(issue: pr_source, pull_request:, actor:)
    }.to raise_error(ArgumentError, /open source issue/)
    expect(SharedDeliveryEvidenceAssociation.where(issue: pr_source)).to be_empty
  end
end
