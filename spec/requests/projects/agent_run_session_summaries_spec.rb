# frozen_string_literal: true

require "rails_helper"

# @spec SESSION-SUMMARY-004
RSpec.describe "Projects::AgentRuns session summaries" do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account:) }
  let(:project) { create(:project, account: account, created_by: owner) }
  let(:agent_run) { create(:agent_run, :completed, project: project) }
  let!(:session_summary) do
    create(:agent_run_session_summary, project: project, agent_run: agent_run,
      summary: "Implemented rate limiting.",
      files_touched: [ "app/services/rate_limiter.rb" ])
  end

  before { sign_in owner }

  describe "GET /projects/:project_id/agent_runs/:id" do
    it "shows the session summary as an observation with a promote action" do
      get project_agent_run_path(project, agent_run)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Session Summary")
      expect(response.body).to include("Implemented rate limiting.")
      expect(response.body).to include("Observation")
      expect(response.body).to include("Promote to Change Intent")
    end
  end

  describe "POST /projects/:project_id/agent_runs/:id/promote_session_summary" do
    it "promotes the summary to a draft change intent and redirects to it" do
      post promote_session_summary_project_agent_run_path(project, agent_run)

      session_summary.reload
      expect(session_summary).to be_promoted
      change_intent = session_summary.change_intent
      expect(change_intent.status).to eq("draft")
      expect(change_intent.intent).to eq("Implemented rate limiting.")
      expect(response).to redirect_to(project_change_intent_path(project, change_intent))
    end

    it "redirects with an alert when the summary is already promoted" do
      session_summary.promote!(change_intent: create(:change_intent, project: project), user: owner)

      post promote_session_summary_project_agent_run_path(project, agent_run)

      expect(response).to redirect_to(project_agent_run_path(project, agent_run))
      follow_redirect!
      expect(response.body).to include("already promoted")
    end

    it "denies a viewer without run-agent access" do
      viewer = create(:user, account: account)
      viewer.add_role(:viewer, account)
      sign_in viewer

      post promote_session_summary_project_agent_run_path(project, agent_run)

      expect(response).to have_http_status(:redirect)
      expect(flash[:alert]).to eq("You are not authorized to perform this action.")
    end
  end
end
