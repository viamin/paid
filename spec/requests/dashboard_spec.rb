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
end
