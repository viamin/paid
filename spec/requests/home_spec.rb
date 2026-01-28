# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Home" do
  describe "GET /" do
    context "when not authenticated" do
      it "renders the home page" do
        get root_path
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Platform for AI Development")
      end

      it "displays sign up and sign in links" do
        get root_path
        expect(response.body).to include("Get started")
        expect(response.body).to include("Sign in")
      end
    end

    context "when authenticated" do
      let(:account) { create(:account) }
      let(:user) { create(:user, account: account) }

      before { sign_in user }

      it "redirects to the dashboard" do
        get root_path
        expect(response).to redirect_to(dashboard_path)
      end
    end
  end
end
