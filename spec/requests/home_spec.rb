# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Home" do
  describe "GET /" do
    context "when not authenticated" do
      it "redirects to sign in" do
        get root_path
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      let(:account) { create(:account) }
      let(:user) { create(:user, account: account) }

      before { sign_in user }

      it "renders the dashboard" do
        get root_path
        expect(response).to have_http_status(:ok)
      end
    end
  end
end
