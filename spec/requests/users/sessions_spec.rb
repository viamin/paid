# frozen_string_literal: true

require "rails_helper"

RSpec.describe "User Sessions" do
  describe "GET /users/sign_in" do
    it "renders the sign in page" do
      get new_user_session_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Sign in to your account")
    end
  end

  describe "POST /users/sign_in" do
    let(:account) { create(:account) }
    let(:user) { create(:user, account: account, password: "password123") }

    context "with valid credentials" do
      it "signs in the user" do
        post user_session_path, params: {
          user: { email: user.email, password: "password123" }
        }
        expect(response).to redirect_to(root_path)
        follow_redirect!
        # Root redirects to dashboard for authenticated users
        expect(response).to redirect_to(dashboard_path)
        follow_redirect!
        expect(response.body).to include(user.email)
      end
    end

    context "with invalid credentials" do
      it "does not sign in the user" do
        post user_session_path, params: {
          user: { email: user.email, password: "wrongpassword" }
        }
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include("Invalid email or password")
      end
    end
  end

  describe "DELETE /users/sign_out" do
    let(:account) { create(:account) }
    let(:user) { create(:user, account: account) }

    it "signs out the user" do
      sign_in user
      delete destroy_user_session_path
      expect(response).to redirect_to(root_path)
    end
  end
end
