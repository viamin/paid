# frozen_string_literal: true

require "rails_helper"
require "securerandom"
require "warden/test/helpers"

RSpec.describe "Chat end-to-end", :chat_e2e, :js, type: :system do
  include Warden::Test::Helpers

  let(:chat_response_timeout) { ENV.fetch("PAID_CHAT_SMOKE_TIMEOUT", "30").to_i }

  let(:unique_suffix) { SecureRandom.hex(6) }
  let!(:account) { create(:account, slug: "chat-e2e-#{unique_suffix}") }
  let!(:user) do
    create(:user, :owner, account: account, email: "chat-e2e-#{unique_suffix}@example.com", password: "password123")
  end

  before do
    Warden.test_mode!
    login_as(user, scope: :user)
  end

  after do
    Warden.test_reset!
  end

  # rubocop:disable RSpec/LeakyLocalVariable
  providers_path = ENV["PAID_CHAT_SMOKE_PROVIDERS_PATH"]
  smoke_providers = if providers_path && File.exist?(providers_path)
    JSON.parse(File.read(providers_path))
  else
    []
  end

  smoke_providers.each_with_index do |provider_config, idx|
    api_key = provider_config["api_key"]
    service_type = provider_config["service_type"]
    model = provider_config["model"]
    label = "#{service_type}/#{model}"

    context "with provider ##{idx + 1}: #{label}", chat_provider: service_type do
      it "sends a message and renders the response via #{label}", :chat_ui do
        test_provider = setup_provider(user, api_key, service_type, model)
        session = ChatSessions::Create.call(
          account: user.account,
          user: user,
          provider_id: test_provider.id,
          model: model
        )

        visit chat_session_path(session)
        expect(page).to have_css("textarea[name='content']", wait: 10)

        response = send_chat_message_json(session.id, "Say exactly: Hello from #{service_type}")
        expect(response["status"]).to eq(201), "JSON API returned #{response['status']}: #{response['body']}"

        visit chat_session_path(session)
        using_wait_time(chat_response_timeout) do
          expect(page).to have_text("Hello from #{service_type}", wait: chat_response_timeout)
        end

        expect(page).not_to have_text("An unexpected error occurred")
      end

      it "sends a message via JSON API using #{label}", :chat_api do
        test_provider = setup_provider(user, api_key, service_type, model)
        session = ChatSessions::Create.call(
          account: user.account,
          user: user,
          provider_id: test_provider.id,
          model: model
        )

        visit chat_session_path(session)
        expect(page).to have_css("textarea[name='content']", wait: 10)

        response = send_chat_message_json(session.id, "Respond with exactly: JSON works")
        expect(response["status"]).to eq(201), "JSON API returned #{response['status']}: #{response['body']}"
        body = JSON.parse(response["body"])
        expect(body["content"]).to be_present
        expect(body["role"]).to eq("assistant")
      end
    end
  end
  # rubocop:enable RSpec/LeakyLocalVariable

  private

  def setup_provider(user, api_key, service_type, model)
    create(:tenant_setting, account: user.account)

    provider_api_key = create(:provider_api_key, user: user, api_key: api_key, api_service_type: service_type)

    provider = user.providers.api_key.find_or_initialize_by(
      provider_key: "opencode",
      provider_api_key: provider_api_key,
      name: "Chat E2E #{service_type}"
    )
    provider.assign_attributes(
      auth_type: "api_key",
      enabled_for_agent_runs: true,
      enabled_for_fallback: false,
      config: {
        "opencode" => {
          "api_provider" => service_type,
          "model" => model
        }
      }
    )
    provider.save!
    provider
  end

  def send_chat_message_json(session_id, content)
    result = page.evaluate_script(<<~JS)
      (function() {
        var xhr = new XMLHttpRequest();
        xhr.open('POST', '/chat/#{session_id}/messages', false);
        xhr.setRequestHeader('Content-Type', 'application/json');
        xhr.setRequestHeader('Accept', 'application/json');
        var token = document.querySelector('meta[name="csrf-token"]');
        if (token) xhr.setRequestHeader('X-CSRF-Token', token.content);
        xhr.send(JSON.stringify({ content: #{JSON.generate(content)} }));
        return JSON.stringify({ status: xhr.status, body: xhr.responseText });
      })()
    JS
    JSON.parse(result)
  end
end
