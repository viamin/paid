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

      it "shows the stacked daily agent runs chart" do
        create(:agent_run, :completed, project: project, created_at: 1.day.ago)
        create(:agent_run, :failed, project: project, created_at: 1.day.ago)

        get dashboard_path

        doc = Nokogiri::HTML(response.body)
        chart = doc.at_css("div#daily-runs-chart")

        expect(response.body).to include("Agent Runs per Day")
        expect(response.body).to include("Completed runs are stacked above failed runs across the last 30 days.")
        expect(chart).to be_present
      end

      it "shows live metrics section with active runs" do
        create(:agent_run, project: project, status: "running", started_at: 5.minutes.ago)
        create(:agent_run, project: project, status: "completed", completed_at: 1.minute.ago, duration_seconds: 42)

        get dashboard_path

        expect(response.body).to include("Live Metrics")
        expect(response.body).to include("Active Runs")
        expect(response.body).to include("Recent Activity")
      end

      it "shows upcoming queue positions only for the signed-in user's projects" do
        owned_project = create(:project, account: account, created_by: user, owner: "visible-owner", repo: "visible-repo")
        other_user = create(:user, account: account)
        hidden_project = create(:project, account: account, created_by: other_user, owner: "hidden-owner", repo: "hidden-repo")

        create(:agent_run, :queued, :manual, project: owned_project, created_at: 2.minutes.ago)
        create(:agent_run, :queued, :manual, project: hidden_project, created_at: 1.minute.ago)

        get dashboard_path

        expect(response.body).to include("Upcoming Queue")
        expect(response.body).to include("visible-owner/visible-repo")
        expect(response.body).to include("Waiting")
        expect(response.body).not_to include("hidden-owner/hidden-repo")
      end

      it "shows orphaned queued projects for the account fallback owner" do
        orphaned_project = create(:project, account: account, created_by: nil, owner: "fallback-owner", repo: "orphaned-repo")

        create(:agent_run, :queued, :manual, project: orphaned_project)

        get dashboard_path

        expect(response.body).to include("fallback-owner/orphaned-repo")
      end

      it "shows active runs and recent activity scoped to the account" do
        create(:agent_run, project: project, status: "running", started_at: 5.minutes.ago)
        create(:agent_run, project: project, status: "completed", completed_at: 1.minute.ago, duration_seconds: 42)

        get dashboard_path

        expect(response.body).to include(project.full_name)
        expect(response.body).to include("42s")
      end

      it "shows quality-paused projects on the dashboard" do
        project.update!(
          name: "Paused Project",
          quality_paused_at: 30.minutes.ago,
          quality_pause_metadata: {
            "composite_score" => 0.34,
            "threshold" => 0.5
          }
        )

        get dashboard_path

        expect(response.body).to include("Quality-paused projects")
        expect(response.body).to include("Paused Project")
        expect(response.body).to include("34.0%")
        expect(response.body).to include(edit_project_path(project))
      end

      it "does not link viewers to quality pause review actions" do
        viewer = create(:user, :viewer, account: account)
        sign_in viewer

        project.update!(name: "Paused Project", quality_paused_at: 30.minutes.ago)

        get dashboard_path

        expect(response.body).to include("Paused Project")
        expect(response.body).to include(project_path(project))
        expect(response.body).not_to include(edit_project_path(project))
      end

      it "does not show quality-paused projects from other accounts" do
        other_account = create(:account)
        other_project = create(:project, account: other_account, quality_paused_at: 30.minutes.ago)

        get dashboard_path

        expect(response.body).not_to include(other_project.name)
      end

      it "includes merged pull requests in the recent activity stream" do
        merged_pr = create(:issue, :pull_request, project: project,
          pr_review_phase: "merged",
          github_number: 1234,
          title: "Ship the thing",
          github_updated_at: 3.minutes.ago)

        get dashboard_path

        expect(response.body).to include("PR ##{merged_pr.github_number}")
        expect(response.body).to include("Ship the thing")
        expect(response.body).to include("Merged")
      end

      it "includes quality pause events in the recent activity stream" do
        create(:quality_pause_event, :paused, project: project,
          composite_score: 0.32,
          threshold: 0.5,
          created_at: 10.minutes.ago)
        create(:quality_pause_event, :resumed, project: project,
          metadata: { resumed_by_user_email: "operator@example.com" },
          created_at: 5.minutes.ago)

        get dashboard_path

        expect(response.body).to include("Automatic work paused by quality gate")
        expect(response.body).to include("32.0% below 50.0%")
        expect(response.body).to include("Quality pause resumed")
        expect(response.body).to include("operator@example.com")
      end

      it "has collapsible sections" do
        get dashboard_path

        doc = Nokogiri::HTML(response.body)
        details_elements = doc.css("details")

        expect(details_elements.length).to eq(4)
      end

      it "collapses recent activity by default" do
        get dashboard_path

        doc = Nokogiri::HTML(response.body)

        live_metrics = doc.at_xpath("//details[summary[contains(text(), 'Live Metrics')]]")
        cumulative = doc.at_xpath("//details[summary[contains(text(), 'Cumulative')]]")
        performance = doc.at_xpath("//details[summary[contains(text(), 'Performance')]]")
        recent_activity = doc.at_xpath("//details[summary[contains(text(), 'Recent Activity')]]")

        expect(live_metrics).to be_present
        expect(cumulative).to be_present
        expect(performance).to be_present
        expect(recent_activity).to be_present

        # First three sections should be open (boolean attribute present)
        expect(live_metrics.has_attribute?("open")).to be true
        expect(cumulative.has_attribute?("open")).to be true
        expect(performance.has_attribute?("open")).to be true
        # Recent Activity should be collapsed (no open attribute)
        expect(recent_activity.has_attribute?("open")).to be false
      end
    end
  end

  describe "GET /dashboard/metrics" do
    let(:account) { create(:account) }
    let(:user) { create(:user, account: account) }

    before { sign_in user }

    it "returns metrics partial within a turbo frame" do
      get dashboard_metrics_path(time_range: "7d")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("dashboard-metrics")
      expect(response.body).to include("Run Volume")
    end

    it "defaults to cumulative when time_range is invalid" do
      get dashboard_metrics_path(time_range: "invalid")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("dashboard-metrics")
    end
  end

  describe "GET /dashboard/performance" do
    let(:account) { create(:account) }
    let(:user) { create(:user, account: account) }

    before { sign_in user }

    it "returns performance partial within a turbo frame" do
      get dashboard_performance_path(status: "all", goal: "all")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("dashboard-performance")
      expect(response.body).to include("Performance by Outcome")
    end

    it "accepts status and goal filters" do
      get dashboard_performance_path(status: "completed", goal: "create_pr")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("dashboard-performance")
    end

    it "defaults invalid filters to all" do
      get dashboard_performance_path(status: "invalid", goal: "invalid")

      expect(response).to have_http_status(:ok)
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

    it "cancels an active run and enqueues background cleanup" do
      agent_run = create(:agent_run, project: project, status: "running", started_at: 2.minutes.ago)

      expect {
        post dashboard_cancel_run_path(agent_run)
      }.to have_enqueued_job(AgentRunCancellationJob).with(agent_run.id)

      expect(response).to redirect_to(dashboard_path)
      expect(response).to have_http_status(:see_other)
      expect(agent_run.reload.status).to eq("cancelled")
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
  end
end
