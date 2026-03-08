# frozen_string_literal: true

require "rails_helper"

RSpec.describe "UserSettings" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }

  describe "GET /user_settings/edit" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        get edit_user_settings_path
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "renders the settings page" do
        get edit_user_settings_path
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Settings")
      end

      it "creates a user_setting record if none exists" do
        expect { get edit_user_settings_path }.to change(UserSetting, :count).by(1)
      end

      it "reuses existing user_setting record" do
        create(:user_setting, user: user)
        expect { get edit_user_settings_path }.not_to change(UserSetting, :count)
      end

      it "displays all setting sections" do
        get edit_user_settings_path
        expect(response.body).to include("Polling & Timing")
        expect(response.body).to include("Agent Execution")
        expect(response.body).to include("Container Resources")
        expect(response.body).to include("Project Defaults")
        expect(response.body).to include("Advanced Settings")
      end
    end
  end

  describe "PATCH /user_settings" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        patch user_settings_path, params: { user_setting: { default_poll_interval_seconds: 120 } }
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "updates polling settings" do
        patch user_settings_path, params: { user_setting: { default_poll_interval_seconds: 120 } }
        expect(response).to redirect_to(edit_user_settings_path)
        expect(user.reload.settings.default_poll_interval_seconds).to eq(120)
      end

      it "updates agent execution settings" do
        user.providers.create!(provider_key: "cursor", enabled_for_agent_runs: true)

        patch user_settings_path, params: {
          user_setting: {
            agent_timeout_seconds: 7200,
            default_agent_provider: "cursor"
          }
        }
        expect(response).to redirect_to(edit_user_settings_path)
        settings = user.reload.settings
        expect(settings.agent_timeout_seconds).to eq(7200)
        expect(settings.default_agent_provider).to eq("cursor")
      end

      it "updates container resource settings" do
        patch user_settings_path, params: {
          user_setting: {
            container_memory_gb: 8,
            container_cpus: 4,
            container_timeout_seconds: 3600
          }
        }
        expect(response).to redirect_to(edit_user_settings_path)
        settings = user.reload.settings
        expect(settings.container_memory_bytes).to eq(8 * 1024 * 1024 * 1024)
        expect(settings.container_cpu_quota).to eq(400_000)
        expect(settings.container_timeout_seconds).to eq(3600)
      end

      it "updates allowed service images setting" do
        patch user_settings_path, params: {
          user_setting: {
            allowed_service_images_csv: "postgres:16, redis:7-alpine"
          }
        }
        expect(response).to redirect_to(edit_user_settings_path)
        settings = user.reload.settings
        expect(settings.allowed_service_images).to eq(%w[postgres:16 redis:7-alpine])
      end

      it "updates project default settings" do
        patch user_settings_path, params: {
          user_setting: {
            default_branch: "develop",
            default_project_active: false,
            default_allowed_github_usernames_csv: "alice, bob"
          }
        }
        expect(response).to redirect_to(edit_user_settings_path)
        settings = user.reload.settings
        expect(settings.default_branch).to eq("develop")
        expect(settings.default_project_active).to be(false)
        expect(settings.default_allowed_github_usernames).to eq(%w[alice bob])
      end

      it "updates advanced settings" do
        patch user_settings_path, params: {
          user_setting: {
            circuit_breaker_failure_threshold: 10,
            retry_max_attempts: 5,
            retry_base_delay: 2.0
          }
        }
        expect(response).to redirect_to(edit_user_settings_path)
        settings = user.reload.settings
        expect(settings.circuit_breaker_failure_threshold).to eq(10)
        expect(settings.retry_max_attempts).to eq(5)
        expect(settings.retry_base_delay).to eq(2.0)
      end

      it "shows a success notice" do
        patch user_settings_path, params: { user_setting: { default_poll_interval_seconds: 120 } }
        expect(flash[:notice]).to eq("Settings saved successfully.")
      end

      it "renders errors for invalid settings" do
        patch user_settings_path, params: { user_setting: { default_poll_interval_seconds: 0 } }
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include("error")
      end

      it "renders errors for invalid agent provider" do
        patch user_settings_path, params: { user_setting: { default_agent_provider: "invalid" } }
        expect(response).to redirect_to(edit_user_settings_path)
        expect(user.reload.settings.default_agent_provider).to eq("claude")
      end

      it "renders errors for blank default branch" do
        patch user_settings_path, params: { user_setting: { default_branch: "" } }
        expect(response).to have_http_status(:unprocessable_content)
      end
    end
  end
end
