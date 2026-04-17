# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe "Onboarding" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }

  before do
    Onboarding::StartOnboarding.call(account: account)
  end

  describe "GET /onboarding" do
    context "when not authenticated" do
      it "redirects to sign in" do
        get onboarding_path
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "renders the onboarding wizard" do
        get onboarding_path
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Welcome to Paid")
        expect(response.body).to include("Setup Progress")
      end

      it "redirects to dashboard if onboarding is already complete" do
        account.update!(onboarding_completed_at: Time.current)
        get onboarding_path
        expect(response).to redirect_to(dashboard_path)
      end
    end
  end

  describe "PATCH /onboarding" do
    before { sign_in user }

    context "with account_profile step" do
      it "updates the account name and advances" do
        patch onboarding_path, params: { step: "account_profile", account: { name: "New Name" } }
        expect(account.reload.name).to eq("New Name")
        expect(account.onboarding_steps.find_by(step: "account_profile").status).to eq("completed")
        expect(response).to redirect_to(onboarding_path)
      end
    end

    context "with github_token step" do
      before do
        Onboarding::CompleteStep.call(account: account, step: "account_profile")
      end

      it "creates a GitHub token and advances" do
        expect {
          patch onboarding_path, params: {
            step: "github_token",
            github_token: { name: "My Token", token: "ghp_#{SecureRandom.alphanumeric(36)}" }
          }
        }.to change { account.github_tokens.count }.by(1)

        expect(account.onboarding_steps.find_by(step: "github_token").status).to eq("completed")
        expect(response).to redirect_to(onboarding_path)
      end
    end

    context "with first_project step" do
      let(:github_token) { create(:github_token, account: account) }
      let(:mock_client) { instance_double(GithubClient) }
      let(:repo_data) { OpenStruct.new(id: 123_456, name: "hello-world", default_branch: "main") }

      before do
        %w[account_profile github_token].each do |step|
          Onboarding::CompleteStep.call(account: account, step: step)
        end
        allow(GithubClient).to receive(:new).and_return(mock_client)
        allow(mock_client).to receive(:repository).and_return(repo_data)
      end

      it "creates a project and advances" do
        expect {
          patch onboarding_path, params: {
            step: "first_project",
            project: {
              name: "My Project",
              owner: "octocat",
              repo: "hello-world",
              github_token_id: github_token.id
            }
          }
        }.to change { account.projects.count }.by(1)

        expect(account.onboarding_steps.find_by(step: "first_project").status).to eq("completed")
      end
    end

    context "with configure_defaults step" do
      before do
        %w[account_profile github_token first_project].each do |step|
          Onboarding::CompleteStep.call(account: account, step: step)
        end
      end

      it "provisions default prompts and style guides" do
        patch onboarding_path, params: { step: "configure_defaults" }

        expect(account.prompts.count).to eq(4)
        expect(account.style_guides.count).to eq(1)
        expect(account.reload.onboarding_completed_at).to be_present
        expect(response).to redirect_to(dashboard_path)
      end
    end
  end

  describe "POST /onboarding/skip" do
    before do
      sign_in user
      %w[account_profile github_token first_project].each do |step|
        Onboarding::CompleteStep.call(account: account, step: step)
      end
    end

    it "skips the configure_defaults step" do
      post skip_onboarding_path, params: { step: "configure_defaults" }

      step = account.onboarding_steps.find_by(step: "configure_defaults")
      expect(step.status).to eq("skipped")
    end

    it "rejects skipping non-skippable steps" do
      post skip_onboarding_path, params: { step: "github_token" }
      expect(response).to redirect_to(onboarding_path)
      expect(flash[:alert]).to include("cannot be skipped")
    end
  end
end
