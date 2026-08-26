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
  let(:owner) { create(:user, :owner) }
  let(:user) { owner }
  let(:project) { create(:project, account: owner.account) }
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
    it "redirects the legacy page to the inbox plan-review filter" do
      get plan_reviews_path

      expect(response).to redirect_to(dashboard_inbox_path(kind: Inbox::Queue::PLAN_REVIEW_KIND))
    end
  end

  describe "POST /plan_reviews/:id/approve" do
    it "rejects viewers who can see the project but cannot mutate it" do
      viewer = create(:user, :viewer, account: owner.account)
      review = create_plan_review(project:, issue:, workflow_id: "workflow-open")
      sign_out owner
      sign_in viewer

      post approve_plan_review_path(review)

      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to include("not authorized")
      expect(workflow_handle).not_to have_received(:signal)
    end

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

      expect(response).to redirect_to(dashboard_inbox_path(kind: Inbox::Queue::PLAN_REVIEW_KIND))
      expect(flash[:alert]).to eq("The plan review workflow is no longer active.")
      expect(flash[:notice]).to be_nil
    end
  end

  describe "POST /plan_reviews/:id/revise" do
    it "signals the workflow with revised tasks" do
      review = create_plan_review(project:, issue:, workflow_id: "workflow-open")

      post revise_plan_review_path(review), params: {
        return_to: dashboard_inbox_path(kind: Inbox::Queue::PLAN_REVIEW_KIND),
        tasks: [
          { title: "Revised task 1", description: "Better approach" },
          { title: "Revised task 2", description: "Follow-up implementation" }
        ]
      }

      expect(response).to redirect_to(dashboard_inbox_path(kind: Inbox::Queue::PLAN_REVIEW_KIND))
      expect(flash[:notice]).to eq("Plan revised. Sub-issues will be created with the updated plan.")
      expect(workflow_handle).to have_received(:signal).with(
        "revise_plan",
        [
          { title: "Revised task 1", description: "Better approach" },
          { title: "Revised task 2", description: "Follow-up implementation" }
        ]
      )
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
