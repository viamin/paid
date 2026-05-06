# frozen_string_literal: true

require "rails_helper"

RSpec.describe "TenantEnforcement" do
  describe "active account" do
    let(:account) { create(:account, status: :active) }
    let(:user) { create(:user, account: account) }

    before { sign_in user }

    it "allows GET requests" do
      get root_path
      expect(response).to have_http_status(:ok)
    end
  end

  describe "suspended account" do
    let(:account) { create(:account, status: :suspended, suspended_at: Time.current) }
    let(:user) { create(:user, :owner, account: account) }

    before { sign_in user }

    it "allows GET requests" do
      get root_path
      expect(response).to have_http_status(:ok)
    end

    it "blocks POST requests with a redirect" do
      post projects_path, params: { project: { name: "test" } }
      expect(response).to redirect_to(root_path)
    end

    it "sets a flash alert for blocked mutations" do
      post projects_path, params: { project: { name: "test" } }
      expect(flash[:alert]).to match(/suspended/i)
    end
  end

  describe "deactivated account" do
    let(:account) { create(:account, status: :deactivated, deactivated_at: Time.current) }
    let(:user) { create(:user, account: account) }

    before { sign_in user }

    it "redirects to sign in on GET" do
      get root_path
      expect(response).to redirect_to(new_user_session_path)
    end

    it "redirects to sign in on POST" do
      post projects_path, params: { project: { name: "test" } }
      expect(response).to redirect_to(new_user_session_path)
    end

    it "sets a deactivation alert" do
      get root_path
      expect(flash[:alert]).to match(/deactivated/i)
    end
  end
end
