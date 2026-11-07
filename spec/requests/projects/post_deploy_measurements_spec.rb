# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Project post-deploy measurements" do
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:, created_by: user) }
  let(:issue) { create(:issue, project:, github_state: "open") }
  let(:identity) { "occurrence-1" }
  let(:check) { PostDeployMeasurements::Registry.find("planning_hold_notifications_actionable") }
  let(:notification) do
    create(:notification, :error, account:, subject: issue, source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE,
      blocking: true,
      metadata: { "prerequisites" => [ { "identity" => identity, "criterion" => "Record the live post-deploy count",
                                         "kind" => "human" } ] })
  end

  before { notification; sign_in user }

  it "requires an authenticated operator" do # @spec POST-DEPLOY-001
    sign_out user

    post project_post_deploy_measurements_path(project), params: request_params

    expect(response).to redirect_to(new_user_session_path)
  end

  it "requests an allowlisted check through the project route without running it inline" do # @spec POST-DEPLOY-001
    allow(PostDeployMeasurementSweepJob).to receive(:perform_later)

    post project_post_deploy_measurements_path(project), params: request_params

    expect(response).to redirect_to(inbox_entry_path("partial_closeout:#{issue.id}"))
    expect(flash[:alert]).to be_nil
    measurement = issue.post_deploy_measurements.sole
    expect(measurement).to have_attributes(status: "pending", check_key: check.key, check_version: check.version)
    expect(measurement.prerequisite_identity).to eq(identity)
    expect(measurement.criterion).to eq("Record the live post-deploy count")
    expect(PostDeployMeasurementSweepJob).to have_received(:perform_later)
  end

  it "rejects a check outside the allowlist" do # @spec POST-DEPLOY-001
    post project_post_deploy_measurements_path(project),
      params: request_params.merge(check_key: "operator_supplied_sql")

    expect(response).to redirect_to(inbox_entry_path("partial_closeout:#{issue.id}"))
    expect(flash[:alert]).to include("not allowlisted")
    expect(issue.post_deploy_measurements).to be_empty
  end

  it "rejects an account viewer without agent-run authorization" do # @spec POST-DEPLOY-001
    viewer = create(:user, :viewer, account:)
    sign_out user
    sign_in viewer

    post project_post_deploy_measurements_path(project), params: request_params

    expect(response).to redirect_to(root_path)
    expect(issue.post_deploy_measurements).to be_empty
  end

  it "does not request a measurement for another project's issue" do # @spec POST-DEPLOY-001
    other_project = create(:project, account:, created_by: user)
    other_issue = create(:issue, project: other_project, github_state: "open")

    post project_post_deploy_measurements_path(project),
      params: request_params.merge(issue_id: other_issue.id)

    expect(response).to redirect_to(inbox_entry_path("partial_closeout:#{issue.id}"))
    expect(flash[:alert]).to be_present
    expect(other_issue.post_deploy_measurements).to be_empty
  end

  private

  def request_params
    { issue_id: issue.id, check_key: check.key, prerequisite_identity: identity,
      inbox_entry_id: "partial_closeout:#{issue.id}" }
  end
end
