# frozen_string_literal: true

require "rails_helper"
require "warden/test/helpers"

RSpec.describe "Chat page layout", :js, system_driver: :paid_cuprite, type: :system do
  include Warden::Test::Helpers

  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account:, password: "password123") }

  before do
    skip "Chromium is not available for Cuprite" unless chromium_path

    Warden.test_mode!
    login_as(user, scope: :user)
    page.current_window.resize_to(390, 844)
  end

  after do
    Warden.test_reset!
  end

  it "preserves transcript height on a mobile workspace chat" do
    # @spec CHAT-API-009
    chat_session = create_mobile_workspace_chat
    visit chat_session_path(chat_session, format: :html)
    expect(page).to have_css("[data-chat-target='container']")

    metrics = chat_layout_metrics

    expect(metrics.fetch("documentScrolls")).to be(false)
    expect(metrics.fetch("transcriptH")).to be >= 288
  end

  def chromium_path
    @chromium_path ||= begin
      configured = ENV["CHROMIUM_PATH"]
      return configured if configured.present? && File.executable?(configured)

      %w[/usr/bin/chromium /usr/bin/chromium-browser /usr/bin/google-chrome /usr/bin/google-chrome-stable]
        .find { |path| File.executable?(path) }
    end
  end

  def create_mobile_workspace_chat
    chat_session = create(
      :chat_session,
      :workspace,
      account:,
      created_by: user,
      container_capability: "ready",
      title: "A very long workspace chat title that previously pushed the transcript into a sliver on mobile"
    )
    12.times do |index|
      chat_session.messages.create!(role: index.even? ? "user" : "assistant", content: "Message #{index}")
    end
    chat_session
  end

  def chat_layout_metrics
    page.evaluate_script(<<~JS)
      (() => {
        const panel = document.querySelector("[data-controller='chat']");
        const transcript = document.querySelector("[data-chat-target='container']");
        const header = panel.querySelector("header");
        const composer = transcript.nextElementSibling;
        const rect = (element) => element.getBoundingClientRect();

        return {
          viewportH: Math.round(window.innerHeight),
          panelH: Math.round(rect(panel).height),
          headerH: Math.round(rect(header).height),
          transcriptH: Math.round(rect(transcript).height),
          composerH: Math.round(rect(composer).height),
          documentScrolls: document.documentElement.scrollHeight > window.innerHeight
        };
      })()
    JS
  end
end
