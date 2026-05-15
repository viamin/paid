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
        expect(response.body).not_to include("Provider Priority")
        expect(response.body).not_to include("Default Agent Provider")
      end

      it "renders the signed-in theme preference as authoritative" do
        user.settings.update!(theme_preference: "dark")

        get edit_user_settings_path

        expect(response.body).to include('data-theme-preference-value="dark"')
        expect(response.body).to include('data-theme-signed-in-value="true"')
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
        expect(response.body).to include("Polling &amp; Timing")
        expect(response.body).to include("Agent Execution")
        expect(response.body).to include("Max Execution Time Override")
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
        allow(ProviderSupport).to receive(:container_executable_provider_keys).and_return(%w[claude cursor])
        cursor = user.providers.create!(provider_key: "cursor", enabled_for_agent_runs: true)

        patch user_settings_path, params: {
          user_setting: {
            agent_timeout_seconds: 7200,
            max_execution_seconds: 5400,
            default_agent_provider: "cursor"
          }
        }
        expect(response).to redirect_to(edit_user_settings_path)
        settings = user.reload.settings
        expect(settings.agent_timeout_seconds).to eq(7200)
        expect(settings.max_execution_seconds).to eq(5400)
        expect(settings.default_agent_provider).to eq(cursor.routing_key)
      end

      it "allows clearing the max execution time override" do
        user.settings.update!(max_execution_seconds: 5400)

        patch user_settings_path, params: {
          user_setting: {
            max_execution_seconds: ""
          }
        }

        expect(response).to redirect_to(edit_user_settings_path)
        expect(user.reload.settings.max_execution_seconds).to be_nil
      end

      it "updates container resource settings" do
        patch user_settings_path, params: {
          user_setting: {
            container_memory_gb: 8,
            max_concurrent_runs: 4,
            container_timeout_seconds: 3600
          }
        }
        expect(response).to redirect_to(edit_user_settings_path)
        settings = user.reload.settings
        expect(settings.container_memory_bytes).to eq(8 * 1024 * 1024 * 1024)
        expect(settings.max_concurrent_runs).to eq(4)
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

      it "updates auto-pick skip labels for the user" do
        patch user_settings_path, params: {
          user_setting: {
            auto_pick_skip_labels_override: "1",
            auto_pick_skip_labels_csv: "planning, research"
          }
        }

        expect(response).to redirect_to(edit_user_settings_path)
        expect(user.reload.settings.auto_pick_skip_labels).to eq(%w[planning research])
      end

      it "allows the user to override defaults with an empty skip-label list" do
        user.settings.update!(auto_pick_skip_labels: %w[planning])

        patch user_settings_path, params: {
          user_setting: {
            auto_pick_skip_labels_override: "1",
            auto_pick_skip_labels_csv: ""
          }
        }

        expect(response).to redirect_to(edit_user_settings_path)
        expect(user.reload.settings.auto_pick_skip_labels).to eq([])
      end

      it "clears the user override when auto-pick skip labels are not overridden" do
        user.settings.update!(auto_pick_skip_labels: %w[planning])

        patch user_settings_path, params: {
          user_setting: {
            auto_pick_skip_labels_override: "0",
            auto_pick_skip_labels_csv: "planning, research"
          }
        }

        expect(response).to redirect_to(edit_user_settings_path)
        expect(user.reload.settings.auto_pick_skip_labels).to be_nil
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

      it "redirects turbo-stream PATCH requests with see other" do
        patch user_settings_path,
          params: { user_setting: { default_poll_interval_seconds: 120 } },
          headers: { "Accept" => "text/vnd.turbo-stream.html" }

        expect(response).to have_http_status(:see_other)
        expect(response).to redirect_to(edit_user_settings_path)
      end

      it "updates theme settings over json" do
        patch user_settings_path,
          params: { user_setting: { theme_preference: "dark" } },
          as: :json

        expect(response).to have_http_status(:ok)
        expect(user.reload.settings.theme_preference).to eq("dark")
      end

      it "renders errors for invalid settings" do
        patch user_settings_path, params: { user_setting: { default_poll_interval_seconds: 0 } }
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include("error")
      end

      it "renders the edit template for invalid turbo-stream requests" do
        patch user_settings_path,
          params: { user_setting: { default_poll_interval_seconds: 0 } },
          headers: { "Accept" => "text/vnd.turbo-stream.html" }

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include("Default Poll Interval")
      end

      it "renders errors for invalid agent provider" do
        patch user_settings_path, params: { user_setting: { default_agent_provider: "invalid" } }
        expect(response).to redirect_to(edit_user_settings_path)
        expect(user.reload.settings.default_agent_provider).to eq(user.providers.find_by!(provider_key: "claude").routing_key)
      end

      it "renders errors for blank default branch" do
        patch user_settings_path, params: { user_setting: { default_branch: "" } }
        expect(response).to have_http_status(:unprocessable_content)
      end

      it "renders errors for malformed knowledge fallback params" do
        user.settings.update!(
          kb_embedding_fallback_providers: [ "openrouter" ],
          kb_chat_fallback_providers: [ "cursor" ]
        )

        patch user_settings_path, params: {
          user_setting: {
            kb_embedding_fallback_providers: "{invalid json",
            kb_chat_fallback_providers: "\"claude\""
          }
        }

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include("must be an array")

        settings = user.reload.settings
        expect(settings.kb_embedding_fallback_providers).to eq([ "openrouter" ])
        expect(settings.kb_chat_fallback_providers).to eq([ "cursor" ])
      end

      it "updates knowledge provider settings from array params" do
        patch user_settings_path, params: {
          user_setting: {
            kb_embedding_provider: "openrouter",
            kb_embedding_fallback_providers: [ "openai", "deepseek" ],
            kb_chat_provider: "claude",
            kb_chat_fallback_providers: [ "cursor" ]
          }
        }

        expect(response).to redirect_to(edit_user_settings_path)

        settings = user.reload.settings
        expect(settings.kb_embedding_provider).to eq("openrouter")
        expect(settings.kb_embedding_fallback_providers).to eq(%w[openai deepseek])
        expect(settings.kb_chat_provider).to eq("claude")
        expect(settings.kb_chat_fallback_providers).to eq([ "cursor" ])
      end

      it "renders errors for unsupported knowledge embedding providers" do
        user.settings.update!(
          kb_embedding_provider: "openai",
          kb_embedding_fallback_providers: [ "openrouter" ]
        )

        patch user_settings_path, params: {
          user_setting: {
            kb_embedding_provider: "anthropic",
            kb_embedding_fallback_providers: [ "openai", "also-not-a-provider" ]
          }
        }

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include("supported knowledge embedding provider")
        expect(response.body).to match(/unsupported providers: also-not-a-provider/i)

        settings = user.reload.settings
        expect(settings.kb_embedding_provider).to eq("openai")
        expect(settings.kb_embedding_fallback_providers).to eq([ "openrouter" ])
      end
    end
  end
end
