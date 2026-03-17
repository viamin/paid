# frozen_string_literal: true

require "rails_helper"

RSpec.describe "AbTests" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:github_token) { create(:github_token, account: account) }
  let(:project) { create(:project, account: account, github_token: github_token) }
  let(:prompt) { create(:prompt, :for_account, :with_version, account: account) }

  describe "GET /prompts/:prompt_id/ab_tests" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        get prompt_ab_tests_path(prompt)
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "renders the index page" do
        get prompt_ab_tests_path(prompt)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("A/B Tests")
      end

      it "shows existing A/B tests" do
        ab_test = create(:ab_test, prompt: prompt, name: "Test Comparison")
        get prompt_ab_tests_path(prompt)
        expect(response.body).to include("Test Comparison")
      end

      it "shows test status" do
        create(:ab_test, prompt: prompt, status: "draft")
        get prompt_ab_tests_path(prompt)
        expect(response.body).to include("Draft")
      end

      it "shows progress information" do
        ab_test = create(:ab_test, prompt: prompt, min_samples_per_variant: 30)
        create(:ab_test_variant, ab_test: ab_test, is_control: true,
               prompt_version: prompt.current_version)
        get prompt_ab_tests_path(prompt)
        expect(response.body).to include("samples")
      end
    end
  end

  describe "GET /prompts/:prompt_id/ab_tests/:id" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        ab_test = create(:ab_test, prompt: prompt)
        get prompt_ab_test_path(prompt, ab_test)
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "shows the A/B test details" do
        ab_test = create(:ab_test, prompt: prompt, name: "My Test")
        get prompt_ab_test_path(prompt, ab_test)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("My Test")
      end

      it "shows variant performance table" do
        ab_test = create(:ab_test, prompt: prompt)
        create(:ab_test_variant, ab_test: ab_test, is_control: true,
               prompt_version: prompt.current_version)
        get prompt_ab_test_path(prompt, ab_test)
        expect(response.body).to include("Variant Performance")
      end

      it "shows control version info" do
        ab_test = create(:ab_test, prompt: prompt)
        get prompt_ab_test_path(prompt, ab_test)
        expect(response.body).to include("Control Version")
      end

      it "shows confidence threshold" do
        ab_test = create(:ab_test, prompt: prompt, confidence_threshold: 0.95)
        get prompt_ab_test_path(prompt, ab_test)
        expect(response.body).to include("95.0%")
      end

      it "shows start button for draft tests" do
        ab_test = create(:ab_test, prompt: prompt, status: "draft")
        get prompt_ab_test_path(prompt, ab_test)
        expect(response.body).to include("Start Test")
      end

      it "shows cancel button for running tests" do
        ab_test = create(:ab_test, prompt: prompt, status: "running", started_at: Time.current)
        get prompt_ab_test_path(prompt, ab_test)
        expect(response.body).to include("Cancel Test")
      end

      it "shows promote button for completed tests with winner" do
        ab_test = create(:ab_test, prompt: prompt, status: "completed", completed_at: Time.current)
        variant = create(:ab_test_variant, ab_test: ab_test)
        ab_test.update!(winner_variant: variant)
        get prompt_ab_test_path(prompt, ab_test)
        expect(response.body).to include("Promote Winner")
      end
    end
  end

  describe "GET /prompts/:prompt_id/ab_tests/new" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        get new_prompt_ab_test_path(prompt)
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "renders the new A/B test form" do
        get new_prompt_ab_test_path(prompt)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("New A/B Test")
      end

      it "shows available prompt versions" do
        prompt.create_version!(template: "Version 2", change_notes: "Second version")
        prompt.create_version!(template: "Version 3", change_notes: "Third version")
        get new_prompt_ab_test_path(prompt)
        expect(response.body).to include("Second version")
      end
    end
  end

  describe "POST /prompts/:prompt_id/ab_tests" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        post prompt_ab_tests_path(prompt), params: { ab_test: { name: "Test" } }
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "creates a new A/B test" do
        old_version = prompt.current_version
        prompt.create_version!(template: "New current template")
        expect {
          post prompt_ab_tests_path(prompt), params: {
            ab_test: {
              name: "New Test",
              variant_version_ids: [ old_version.id ],
              min_samples_per_variant: 30,
              confidence_threshold: 0.95
            }
          }
        }.to change(AbTest, :count).by(1)
      end

      it "redirects to the A/B test page" do
        old_version = prompt.current_version
        prompt.create_version!(template: "New current template")
        post prompt_ab_tests_path(prompt), params: {
          ab_test: {
            name: "New Test",
            variant_version_ids: [ old_version.id ],
            min_samples_per_variant: 30,
            confidence_threshold: 0.95
          }
        }
        expect(response).to redirect_to(prompt_ab_test_path(prompt, AbTest.last))
        expect(flash[:notice]).to include("successfully created")
      end

      it "re-renders the form with errors on invalid input" do
        post prompt_ab_tests_path(prompt), params: {
          ab_test: {
            name: "New Test",
            variant_version_ids: [],
            min_samples_per_variant: 30,
            confidence_threshold: 0.95
          }
        }
        expect(response).to have_http_status(:unprocessable_content)
      end
    end
  end

  describe "POST /prompts/:prompt_id/ab_tests/:id/start" do
    context "when authenticated" do
      before { sign_in user }

      it "starts a draft A/B test" do
        ab_test = create(:ab_test, prompt: prompt, status: "draft")
        create(:ab_test_variant, ab_test: ab_test, is_control: true,
               prompt_version: prompt.current_version)
        post start_prompt_ab_test_path(prompt, ab_test)
        expect(ab_test.reload.status).to eq("running")
        expect(response).to redirect_to(prompt_ab_test_path(prompt, ab_test))
      end

      it "shows error when starting a non-draft test" do
        ab_test = create(:ab_test, prompt: prompt, status: "completed", completed_at: Time.current)
        post start_prompt_ab_test_path(prompt, ab_test)
        expect(response).to redirect_to(prompt_ab_test_path(prompt, ab_test))
        expect(flash[:alert]).to be_present
      end
    end
  end

  describe "POST /prompts/:prompt_id/ab_tests/:id/cancel" do
    context "when authenticated" do
      before { sign_in user }

      it "cancels a running A/B test" do
        ab_test = create(:ab_test, prompt: prompt, status: "running", started_at: Time.current)
        post cancel_prompt_ab_test_path(prompt, ab_test)
        expect(ab_test.reload.status).to eq("cancelled")
        expect(response).to redirect_to(prompt_ab_test_path(prompt, ab_test))
      end

      it "cancels a draft A/B test" do
        ab_test = create(:ab_test, prompt: prompt, status: "draft")
        post cancel_prompt_ab_test_path(prompt, ab_test)
        expect(ab_test.reload.status).to eq("cancelled")
      end
    end
  end

  describe "POST /prompts/:prompt_id/ab_tests/:id/promote" do
    context "when authenticated" do
      before { sign_in user }

      it "promotes the winning variant" do
        ab_test = create(:ab_test, prompt: prompt, status: "completed", completed_at: Time.current)
        variant = create(:ab_test_variant, ab_test: ab_test)
        ab_test.update!(winner_variant: variant)
        post promote_prompt_ab_test_path(prompt, ab_test)
        expect(prompt.reload.current_version).to eq(variant.prompt_version)
        expect(response).to redirect_to(prompt_ab_test_path(prompt, ab_test))
        expect(flash[:notice]).to include("promoted")
      end

      it "shows error when no winner" do
        ab_test = create(:ab_test, prompt: prompt, status: "completed", completed_at: Time.current)
        post promote_prompt_ab_test_path(prompt, ab_test)
        expect(response).to redirect_to(prompt_ab_test_path(prompt, ab_test))
        expect(flash[:alert]).to be_present
      end
    end
  end
end
