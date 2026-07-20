# frozen_string_literal: true

require "rails_helper"

RSpec.describe "chat_sessions/_session_card", :no_db, type: :view do
  let(:project) { Struct.new(:id, :name).new(7, "Platform") }
  let(:provider) { Struct.new(:display_name).new("OpenAI") }
  let(:chat_session) do
    Struct.new(
      :id,
      :to_param,
      :title,
      :provider,
      :model,
      :updated_at,
      :status,
      :mode,
      :project,
      :projects,
      :archived?,
      keyword_init: true
    ).new(
      id: 42,
      to_param: "42",
      title: "Investigate CI failure",
      provider: provider,
      model: "gpt-5.4",
      updated_at: Time.zone.parse("2026-05-15 00:00:00 UTC"),
      status: "active",
      mode: "workspace",
      project: project,
      projects: [ project ],
      archived?: false
    )
  end

  before do
    allow(view).to receive(:dom_id).with(chat_session).and_return("chat_session_42")
    allow(view).to receive(:chat_session_title).with(chat_session).and_return("Investigate CI failure")
    allow(view).to receive(:chat_session_preview).with(chat_session).and_return("Review failing specs")
    allow(view).to receive(:chat_session_projects).with(chat_session).and_return([ project ])
    allow(view).to receive(:chat_session_status_badge).with(chat_session).and_return('<span>Active</span>'.html_safe)
    allow(view).to receive(:chat_mode_badge).with(chat_session.mode).and_return('<span>Workspace</span>'.html_safe)
    allow(view).to receive(:local_time).with(chat_session.updated_at, format: :relative).and_return("5 minutes ago")
    allow(view).to receive(:chat_session_member_path).with(chat_session).and_return("/chat/42")
  end

  it "renders the session link without relying on route helper availability" do
    render partial: "chat_sessions/session_card", locals: { chat_session: chat_session }

    expect(rendered).to include('href="/chat/42"')
    expect(rendered).to include("Investigate CI failure")
  end
end
