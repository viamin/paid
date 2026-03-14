# frozen_string_literal: true

require "rails_helper"

RSpec.describe "AbTests" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:prompt) { create(:prompt, account: account) }

  describe "GET /ab_tests" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        get ab_tests_path
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "renders the index page" do
        get ab_tests_path
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("A/B Tests")
      end
    end
  end

  describe "GET /ab_tests/:id" do
    let(:ab_test) { create(:ab_test, :with_variants, prompt: prompt, account: account) }

    context "when authenticated" do
      before { sign_in user }

      it "renders the show page" do
        get ab_test_path(ab_test)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include(ab_test.name)
      end
    end
  end

  describe "POST /ab_tests" do
    before { sign_in user }

    it "creates a new A/B test" do
      expect {
        post ab_tests_path, params: {
          ab_test: {
            name: "Test Prompt Versions",
            prompt_id: prompt.id,
            traffic_percentage: 100,
            min_sample_size: 30
          }
        }
      }.to change(AbTest, :count).by(1)

      expect(response).to redirect_to(ab_test_path(AbTest.last))
    end
  end

  describe "POST /ab_tests/:id/start" do
    before { sign_in user }

    it "starts a draft test with variants" do
      ab_test = create(:ab_test, :with_variants, prompt: prompt, account: account)

      post start_ab_test_path(ab_test)

      expect(ab_test.reload.status).to eq("running")
      expect(response).to redirect_to(ab_test_path(ab_test))
    end
  end
end
