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
    expect(page).to have_css("[data-controller='chat'][style*='--chat-panel-offset-top:']")

    metrics = settled_chat_layout_metrics

    expect(metrics.fetch("panelBottomGap")).to be_between(-2, 4).inclusive
    expect(metrics.fetch("documentOverflow")).to be <= 4
    expect(metrics.fetch("transcriptH")).to be >= 288
    expect(metrics.fetch("transcriptShare")).to be >= 0.45
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
        const header = panel.querySelector("[data-chat-header='mobile']");
        const composer = transcript.nextElementSibling;
        const rect = (element) => element.getBoundingClientRect();
        const viewportH = Math.round(window.visualViewport?.height || window.innerHeight);
        const panelRect = rect(panel);
        const transcriptRect = rect(transcript);

        return {
          viewportH,
          panelH: Math.round(panelRect.height),
          panelBottomGap: Number((viewportH - panelRect.bottom).toFixed(2)),
          headerH: Math.round(rect(header).height),
          transcriptH: Math.round(transcriptRect.height),
          transcriptShare: Number((transcriptRect.height / panelRect.height).toFixed(3)),
          composerH: Math.round(rect(composer).height),
          documentOverflow: Number((document.documentElement.scrollHeight - viewportH).toFixed(2))
        };
      })()
    JS
  end

  # Cuprite can observe the inline `--chat-panel-offset-top` style before the
  # browser has finished the layout pass that applies it. Poll through
  # Capybara's waiter until the viewport-bound panel has actually settled, then
  # assert the mobile transcript geometry against the final layout. Use a small
  # tolerance: Chrome reports fractional layout pixels, and rounding those to
  # integers turns a truly flush panel/non-scrolling document into a noisy
  # off-by-one or off-by-two failure on CI.
  def settled_chat_layout_metrics
    page.document.synchronize do
      metrics = chat_layout_metrics
      return metrics if settled_chat_layout?(metrics)

      raise Capybara::ExpectationNotMet, "chat layout has not settled yet: #{metrics.inspect}"
    end
  end

  def settled_chat_layout?(metrics)
    metrics.fetch("panelBottomGap").between?(-2, 4) &&
      metrics.fetch("documentOverflow") <= 4 &&
      metrics.fetch("transcriptH").positive?
  end
end
