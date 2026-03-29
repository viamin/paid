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
      let(:project) { create(:project, account: account) }

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

      it "shows live metrics section with active runs" do
        create(:agent_run, project: project, status: "running", started_at: 5.minutes.ago)
        create(:agent_run, project: project, status: "completed", completed_at: 1.minute.ago, duration_seconds: 42)

        get dashboard_path

        expect(response.body).to include("Live Metrics")
        expect(response.body).to include("Active Runs")
        expect(response.body).to include("Recent Activity")
      end

      it "shows active runs and recent activity scoped to the account" do
        create(:agent_run, project: project, status: "running", started_at: 5.minutes.ago)
        create(:agent_run, project: project, status: "completed", completed_at: 1.minute.ago, duration_seconds: 42)

        get dashboard_path

        expect(response.body).to include(project.full_name)
        expect(response.body).to include("42s")
      end

      it "has collapsible sections" do
        get dashboard_path

        doc = Nokogiri::HTML(response.body)
        details_elements = doc.css("details")

        expect(details_elements.length).to eq(3)
      end

      it "collapses recent activity by default" do
        get dashboard_path

        doc = Nokogiri::HTML(response.body)

        live_metrics = doc.at_xpath("//details[summary[contains(text(), 'Live Metrics')]]")
        cumulative = doc.at_xpath("//details[summary[contains(text(), 'Cumulative')]]")
        recent_activity = doc.at_xpath("//details[summary[contains(text(), 'Recent Activity')]]")

        expect(live_metrics).to be_present
        expect(cumulative).to be_present
        expect(recent_activity).to be_present

        # First two sections should be open (boolean attribute present)
        expect(live_metrics.has_attribute?("open")).to be true
        expect(cumulative.has_attribute?("open")).to be true
        # Recent Activity should be collapsed (no open attribute)
        expect(recent_activity.has_attribute?("open")).to be false
      end
    end
  end

  describe "GET /dashboard/live" do
    it "redirects to the dashboard" do
      get dashboard_live_path
      expect(response).to redirect_to(dashboard_path)
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

      expect(response).to redirect_to(dashboard_path)
      expect(response).to have_http_status(:see_other)
      expect(AgentRuns::Cancel).to have_received(:call).with(agent_run: agent_run, skip_status_update: true)
      expect(agent_run.reload.status).to eq("cancelled")
    end

    it "redirects with an alert when external cancellation fails" do
      agent_run = create(:agent_run, project: project, status: "running", started_at: 2.minutes.ago)

      allow(AgentRuns::Cancel).to receive(:call).and_raise(StandardError, "Temporal unavailable")

      post dashboard_cancel_run_path(agent_run)

      expect(response).to redirect_to(dashboard_path)
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

      expect(response).to redirect_to(dashboard_path)
      expect(response).to have_http_status(:see_other)
      expect(flash[:notice]).to eq("Agent run is no longer active.")
    end

    it "shows a different message when the run finishes during external cancellation" do
      agent_run = create(:agent_run, project: project, status: "running", started_at: 2.minutes.ago)

      # Simulate the run finishing during external cleanup by updating the
      # database record when Cancel is called.  The controller reloads
      # @agent_run inside with_lock, so stubbing the instance wouldn't work.
      allow(AgentRuns::Cancel).to receive(:call) do
        agent_run.update_column(:status, "completed")
      end

      post dashboard_cancel_run_path(agent_run)

      expect(response).to redirect_to(dashboard_path)
      expect(response).to have_http_status(:see_other)
      expect(flash[:notice]).to eq("Agent run finished before it could be cancelled.")
    end
  end
end
