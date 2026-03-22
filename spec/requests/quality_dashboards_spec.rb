# frozen_string_literal: true

require "rails_helper"

RSpec.describe "QualityDashboards" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }

  describe "GET /quality_dashboard" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        get quality_dashboard_path
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "renders the dashboard" do
        get quality_dashboard_path
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Quality Metrics")
      end
    end
  end
end
