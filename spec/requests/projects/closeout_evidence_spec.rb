# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Project closeout evidence" do
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:, created_by: user) }
  let(:issue) { create(:issue, project:, github_state: "open") }
  let(:identity) { "occurrence-1" }
  let(:notification) do
    create(:notification, :error, account:, subject: issue, source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE,
      blocking: true, metadata: { "prerequisites" => [ { "identity" => identity } ] })
  end

  before { sign_in user }

  it "requires an authenticated operator" do # @spec PARTIAL-CLOSEOUT-033
    sign_out user

    post project_closeout_evidence_index_path(project), params: evidence_params

    expect(response).to redirect_to(new_user_session_path)
  end

  it "records authorized evidence through the project route" do # @spec PARTIAL-CLOSEOUT-033
    post project_closeout_evidence_index_path(project), params: evidence_params

    expect(response).to redirect_to(inbox_entry_path("partial_closeout:#{issue.id}"))
    expect(flash[:alert]).to be_nil
    expect(notification.reload.metadata.fetch("evidence_submissions")).to contain_exactly(
      include("prerequisite_identity" => identity, "actor_id" => user.id, "outcome" => "pending_validation")
    )
  end

  it "rejects an account viewer without agent-run authorization" do # @spec PARTIAL-CLOSEOUT-033
    viewer = create(:user, :viewer, account:)
    sign_out user
    sign_in viewer

    post project_closeout_evidence_index_path(project), params: evidence_params

    expect(response).to redirect_to(root_path)
    expect(notification.reload.metadata).not_to have_key("evidence_submissions")
  end

  it "does not accept a notification owned by another project" do # @spec PARTIAL-CLOSEOUT-033
    other_project = create(:project, account:, created_by: user)
    other_issue = create(:issue, project: other_project, github_state: "open")
    other_notification = create(:notification, :error, account:, subject: other_issue,
      source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE, blocking: true,
      metadata: { "prerequisites" => [ { "identity" => identity } ] })

    post project_closeout_evidence_index_path(project), params: evidence_params.merge(notification_id: other_notification.id)

    expect(response).to redirect_to(inbox_entry_path("partial_closeout:#{issue.id}"))
    expect(other_notification.reload.metadata).not_to have_key("evidence_submissions")
  end

  it "falls back to the Inbox after recording evidence without an entry id" do # @spec PARTIAL-CLOSEOUT-033
    post project_closeout_evidence_index_path(project), params: evidence_params.except(:inbox_entry_id)

    expect(response).to redirect_to(inbox_path)
    expect(notification.reload.metadata.fetch("evidence_submissions")).to contain_exactly(
      include("prerequisite_identity" => identity, "outcome" => "pending_validation")
    )
  end

  private

  def evidence_params
    { notification_id: notification.id, prerequisite_identity: identity, inbox_entry_id: "partial_closeout:#{issue.id}",
      "prerequisite_#{identity}" => { evidence_url: "https://evidence.example.test/report", explanation: "Pilot report attached." } }
  end
end
