# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Dashboard" do
  describe "GET /dashboard" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        get dashboard_path
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      let(:account) { create(:account, name: "Test Company") }
      let(:user) { create(:user, account: account, name: "John Doe") }

      before { sign_in user }

      it "renders the dashboard" do
        get dashboard_path
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Dashboard")
      end

      it "displays the user name" do
        get dashboard_path
        expect(response.body).to include("John Doe")
      end

      it "displays the account name" do
        get dashboard_path
        expect(response.body).to include("Test Company")
      end

      it "includes settings in the mobile menu" do
        get dashboard_path

        doc = Nokogiri::HTML(response.body)
        mobile_settings_link = doc.at_css("#mobile-menu a[href='#{edit_user_settings_path}']")

        expect(mobile_settings_link).to be_present
        expect(mobile_settings_link.text.strip).to eq("Settings")
      end

      it "shows the run phase breakdown section" do
        get dashboard_path

        expect(response.body).to include("Run Phase Breakdown")
        expect(response.body).to include("Average End-to-End Composition")
        expect(response.body).to include('aria-label="Average end-to-end composition by phase"')
      end
    end
  end

  describe "GET /dashboard/live" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        get live_dashboard_path
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      let(:account) { create(:account, name: "Test Company") }
      let(:user) { create(:user, account: account, name: "John Doe") }
      let(:project) { create(:project, account: account) }

      before { sign_in user }

      it "renders the live dashboard" do
        create(:agent_run, project: project, status: "running", started_at: 5.minutes.ago)
        create(:agent_run, project: project, status: "completed", completed_at: 1.minute.ago, duration_seconds: 42)

        get live_dashboard_path

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Live Dashboard")
        expect(response.body).to include("Active Runs")
        expect(response.body).to include("Recent Activity")
      end

      it "shows active runs and recent activity scoped to the account" do
        create(:agent_run, project: project, status: "running", started_at: 5.minutes.ago)
        create(:agent_run, project: project, status: "completed", completed_at: 1.minute.ago, duration_seconds: 42)

        get live_dashboard_path

        expect(response.body).to include(project.full_name)
        expect(response.body).to include("42s")
      end
    end
  end

  describe "POST /dashboard/cancel_run/:id" do
    let(:account) { create(:account) }
    let(:user) { create(:user, account: account) }
    let(:project) { create(:project, account: account) }

    before { sign_in user }

    it "cancels an active run through AgentRuns::Cancel" do
      agent_run = create(:agent_run, project: project, status: "running", started_at: 2.minutes.ago)

      allow(AgentRuns::Cancel).to receive(:call)

      post dashboard_cancel_run_path(agent_run)

      expect(response).to redirect_to(live_dashboard_path)
      expect(response).to have_http_status(:see_other)
      expect(AgentRuns::Cancel).to have_received(:call).with(agent_run: agent_run, skip_status_update: true)
      expect(agent_run.reload.status).to eq("cancelled")
    end

    it "redirects with an alert when external cancellation fails" do
      agent_run = create(:agent_run, project: project, status: "running", started_at: 2.minutes.ago)

      allow(AgentRuns::Cancel).to receive(:call).and_raise(StandardError, "Temporal unavailable")

      post dashboard_cancel_run_path(agent_run)

      expect(response).to redirect_to(live_dashboard_path)
      expect(response).to have_http_status(:see_other)
      expect(flash[:alert]).to eq("Unable to cancel agent run. Please try again.")
      expect(agent_run.reload.status).to eq("running")
    end

    it "returns not found for a run in another account" do
      other_run = create(:agent_run, status: "running", started_at: 1.minute.ago)

      post dashboard_cancel_run_path(other_run)

      expect(response).to have_http_status(:not_found)
    end

    it "redirects when the run is already finished" do
      agent_run = create(:agent_run, project: project, status: "completed", completed_at: Time.current)

      post dashboard_cancel_run_path(agent_run)

      expect(response).to redirect_to(live_dashboard_path)
      expect(response).to have_http_status(:see_other)
      expect(flash[:notice]).to eq("Agent run is no longer active.")
    end
  end
end
