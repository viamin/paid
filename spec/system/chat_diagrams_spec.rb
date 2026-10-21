# frozen_string_literal: true

require "rails_helper"
require "warden/test/helpers"

RSpec.describe "Chat diagrams", :js, system_driver: :paid_cuprite, type: :system do
  include Warden::Test::Helpers

  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account:, password: "password123") }
  let(:chat_session) { create(:chat_session, account:, created_by: user) }

  before do
    skip "Chromium is not available for Cuprite" unless chromium_path

    Warden.test_mode!
    login_as(user, scope: :user)
  end

  after { Warden.test_reset! }

  # @spec QUESTION-EXPLORATION-003 QUESTION-EXPLORATION-011
  it "supports keyboard selection and preserves an unsent comment while expanded" do
    diagram = create(:chat_diagram, chat_session:)
    visit chat_session_path(chat_session)

    details = find("[data-chat-diagram-id='#{diagram.id}'] details")
    find("[data-chat-diagram-id='#{diagram.id}'] summary").click
    expect(details[:open]).not_to be_nil

    find("[data-chat-diagram-id='#{diagram.id}'] [data-diagram-element-id='app']").send_keys(:space)
    expect(find("[data-chat-diagram-id='#{diagram.id}'] [data-diagram-element-id='app']")["aria-pressed"]).to eq("true")

    comment = find("[data-chat-diagram-id='#{diagram.id}'] textarea[name='body']")
    comment.fill_in(with: "Keep this explanation")
    find("[data-chat-diagram-id='#{diagram.id}'] summary").click

    expect(details[:open]).not_to be_nil
    expect(comment.value).to eq("Keep this explanation")
    expect(page.evaluate_script("document.activeElement.name")).to eq("body")
  end

  # @spec QUESTION-EXPLORATION-003 QUESTION-EXPLORATION-012
  it "inserts a diagram received through the chat transport" do
    visit chat_session_path(chat_session)
    diagram = build_stubbed(:chat_diagram, chat_session:, current: false)
    html = ApplicationController.render(partial: "chat_diagrams/diagram", locals: { diagram:, chat_session: })

    page.execute_script(<<~JS, { type: "diagram_created", diagram_id: diagram.id, question_key: diagram.question_key, html: })
      const chat = window.Stimulus.getControllerForElementAndIdentifier(
        document.querySelector("[data-controller~='chat']"), "chat"
      )
      chat.handleEvent(arguments[0])
    JS

    expect(page).to have_css("[data-chat-diagram-id='#{diagram.id}']")
  end

  # @spec QUESTION-EXPLORATION-003 QUESTION-EXPLORATION-012
  it "does not duplicate a live diagram when its tool result arrives" do
    visit chat_session_path(chat_session)
    diagram = create(:chat_diagram, chat_session:)
    tool_result = create(:chat_message, :tool, chat_session:)
    diagram.update!(chat_message: tool_result)
    diagram_html = ApplicationController.render(partial: "chat_diagrams/diagram", locals: { diagram:, chat_session: })
    message_html = ApplicationController.render(partial: "chat_messages/message", locals: { message: tool_result })

    page.execute_script(<<~JS, { type: "diagram_created", diagram_id: diagram.id, question_key: diagram.question_key, html: diagram_html })
      const chat = window.Stimulus.getControllerForElementAndIdentifier(
        document.querySelector("[data-controller~='chat']"), "chat"
      )
      chat.handleEvent(arguments[0])
    JS
    page.execute_script(<<~JS, { type: "message_created", message_id: tool_result.id, html: message_html })
      const chat = window.Stimulus.getControllerForElementAndIdentifier(
        document.querySelector("[data-controller~='chat']"), "chat"
      )
      chat.handleEvent(arguments[0])
    JS

    expect(page).to have_css("[data-chat-diagram-id='#{diagram.id}']", count: 1)
  end
end
