# frozen_string_literal: true

require "rails_helper"
require "warden/test/helpers"

RSpec.describe "Unstarted chat drafts", type: :system do
  include Warden::Test::Helpers

  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account:) }

  before do
    Warden.test_mode!
    login_as(user, scope: :user)
  end

  after { Warden.test_reset! }

  # @spec CHAT-API-030
  it "reuses the personal draft when the full-page chat is loaded again" do
    visit chat_sessions_path(format: :html)
    original = ChatSession.unstarted_untitled_personal.where(created_by: user).sole

    visit chat_sessions_path(format: :html)

    expect(ChatSession.unstarted_untitled_personal.where(created_by: user)).to contain_exactly(original)
    expect(page).to have_current_path(chat_session_path(original), ignore_query: true)
  end
end
