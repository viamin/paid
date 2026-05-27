# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Accounts::RoiDashboards" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }

  describe "GET /account_roi_dashboard" do
    it "redirects unauthenticated users" do
      get account_roi_dashboard_path

      expect(response).to redirect_to(new_user_session_path)
    end

    it "renders the account ROI dashboard for authenticated users" do
      sign_in user

      get account_roi_dashboard_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Account ROI Dashboard")
      expect(response.body).to include("Project Rollup")
      expect(response.body).to include("Trend Analysis")
    end
  end

  describe "GET /account_roi_dashboard/export" do
    it "returns a CSV report" do
      sign_in user

      get export_account_roi_dashboard_path(format: :csv)

      expect(response).to have_http_status(:ok)
      expect(response.content_type).to include("text/csv")
      expect(response.body).to include("Account Current")
      expect(response.body).to include("Projects")
    end
  end
end
