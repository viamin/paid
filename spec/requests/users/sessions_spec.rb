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
        # Root is the dashboard for authenticated users
        expect(response).to have_http_status(:ok)
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

      it "displays the error inline within the login form" do
        post user_session_path, params: {
          user: { email: user.email, password: "wrongpassword" }
        }
        doc = Nokogiri::HTML(response.body)

        # Error appears inside the inline alert container (within the form card)
        inline_alert = doc.at_css("[data-turbo-temporary]")
        expect(inline_alert).to be_present
        expect(inline_alert.text).to include("Invalid email or password")

        # Layout-level flash alert is suppressed (content_for(:inline_alert) prevents it)
        expect(doc.at_css("body > div.mx-auto .bg-red-50")).not_to be_present
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
