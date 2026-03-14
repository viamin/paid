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
      let(:user) { create(:user, account: account) }
      let(:project) { create(:project, account: account) }

      before { sign_in user }

      it "renders the live dashboard" do
        get live_dashboard_path
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Live Dashboard")
      end

      it "displays active runs" do
        create(:agent_run, :running, project: project)
        get live_dashboard_path
        expect(response.body).to include("Active Runs")
      end

      it "displays live stats" do
        get live_dashboard_path
        expect(response.body).to include("Active Runs")
        expect(response.body).to include("Queued")
        expect(response.body).to include("Completed Today")
        expect(response.body).to include("Failed Today")
      end

      it "displays recent activity" do
        get live_dashboard_path
        expect(response.body).to include("Recent Activity")
      end

      it "includes the live indicator" do
        get live_dashboard_path
        expect(response.body).to include("live-indicator")
      end
    end
  end

  describe "POST /dashboard/cancel_run/:id" do
    let(:account) { create(:account) }
    let(:user) { create(:user, account: account) }
    let(:project) { create(:project, account: account) }

    before { sign_in user }

    it "cancels a running agent run" do
      agent_run = create(:agent_run, :running, project: project)
      post dashboard_cancel_run_path(agent_run)
      expect(response).to have_http_status(:ok)
      expect(agent_run.reload.status).to eq("cancelled")
    end

    it "returns not found for runs from other accounts" do
      other_account = create(:account)
      other_project = create(:project, account: other_account)
      other_run = create(:agent_run, :running, project: other_project)

      expect {
        post dashboard_cancel_run_path(other_run)
      }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
