# frozen_string_literal: true

require "rails_helper"
require "temporalio"

class PlanReviewWorkflowHandleDouble
  def signal(*); end
end

class PlanReviewTemporalClientDouble
  def workflow_handle(*); end

  def start_workflow(*); end
end

RSpec.describe "Plan reviews" do
  let(:user) { create(:user, :owner) }
  let(:project) { create(:project, account: user.account) }
  let(:issue) { create(:issue, project:) }
  let(:workflow_handle) { instance_double(PlanReviewWorkflowHandleDouble, signal: true) }
  let(:temporal_client) do
    instance_double(PlanReviewTemporalClientDouble, workflow_handle:, start_workflow: true)
  end

  before do
    allow(Paid).to receive(:temporal_client).and_return(temporal_client)
    sign_in user
  end

  describe "GET /plan_reviews" do
    it "shows only still-open pending reviews in the signed-in user's scope" do
      visible_review = create_plan_review(
        project:,
        issue:,
        workflow_id: "workflow-open",
        plan_data: { "tasks" => [ { "title" => "Visible task", "description" => "Visible description" } ] }
      )
      stale_issue = create(:issue, project:)
      create_closed_plan_review(project:, issue: stale_issue, workflow_id: "workflow-closed")
      other_account = create(:account)
      hidden_project = create(:project, account: other_account)
      hidden_issue = create(:issue, project: hidden_project)
      create_plan_review(project: hidden_project, issue: hidden_issue, workflow_id: "workflow-hidden")

      get plan_reviews_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(visible_review.issue.title, "Visible task")
      expect(response.body).not_to include(stale_issue.title, hidden_issue.title)
    end
  end

  describe "POST /plan_reviews/:id/approve" do
    it "does not allow approving a review outside the user's scope" do
      other_account = create(:account)
      hidden_project = create(:project, account: other_account)
      hidden_issue = create(:issue, project: hidden_project)
      hidden_review = create_plan_review(project: hidden_project, issue: hidden_issue, workflow_id: "workflow-hidden")

      post approve_plan_review_path(hidden_review)

      expect(response).to have_http_status(:not_found)
      expect(workflow_handle).not_to have_received(:signal)
    end

    it "does not allow re-approving a review once a later workflow decision exists" do
      pending_review = create_closed_plan_review(project:, issue:, workflow_id: "workflow-closed")

      post approve_plan_review_path(pending_review)

      expect(response).to have_http_status(:not_found)
      expect(workflow_handle).not_to have_received(:signal)
    end

    it "short-circuits with an alert when the workflow is no longer active" do
      review = create_plan_review(project:, issue:, workflow_id: "workflow-missing")
      allow(workflow_handle).to receive(:signal).and_raise(
        Temporalio::Error::RPCError.new(
          "not found",
          code: Temporalio::Error::RPCError::Code::NOT_FOUND,
          raw_grpc_status: nil
        )
      )

      post approve_plan_review_path(review)

      expect(response).to redirect_to(plan_reviews_path)
      expect(flash[:alert]).to eq("The plan review workflow is no longer active.")
      expect(flash[:notice]).to be_nil
    end
  end

  def create_plan_review(project:, issue:, workflow_id:, plan_data: nil)
    create(
      :decomposition_decision,
      project:,
      issue:,
      workflow_id:,
      decision_key: "#{workflow_id}:plan_review:pending",
      decision_type: "planning_outcome",
      outcome: "plan_pending_review",
      plan_data: plan_data || { "tasks" => [], "created_issues" => [] }
    )
  end

  def create_closed_plan_review(project:, issue:, workflow_id:)
    create_plan_review(project:, issue:, workflow_id:).tap do
      create(
        :decomposition_decision,
        project:,
        issue:,
        workflow_id:,
        decision_key: "#{workflow_id}:plan_review:approved",
        decision_type: "planning_outcome",
        outcome: "plan_review_approved"
      )
    end
  end
end
