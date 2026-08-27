# frozen_string_literal: true

require "rails_helper"
require "warden/test/helpers"

RSpec.describe "Chat workspace continuity", :js, type: :system do
  include ActiveJob::TestHelper
  include Warden::Test::Helpers

  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account:, password: "password123") }
  let(:project) { create(:project, account:) }
  let(:other_project) { create(:project, account:) }
  let(:container) { instance_double(Docker::Container, id: "restored-container") }
  let(:backend) { instance_double(Containers::Backends::Base) }

  before do
    Warden.test_mode!
    login_as(user, scope: :user)

    allow(Containers::ProvisionForChat).to receive(:call) do |chat_session:, **|
      chat_session.update!(
        container_capability: "ready",
        container_id: "restored-container",
        container_ready_at: Time.current
      )
    end

    allow(Containers).to receive(:backend).and_return(backend)
    allow(backend).to receive_messages(
      get_container: container,
      exec_in_container: [ [], [], 0 ]
    )
  end

  after do
    clear_enqueued_jobs
    clear_performed_jobs
    Warden.test_reset!
  end

  it "reopens a stopped workspace and preserves conversation history" do
    session = create(:chat_session, :closed, :workspace, account:, created_by: user, container_capability: "stopped", container_id: nil)
    session.messages.create!(role: "assistant", content: "Existing conversation")
    session.update!(clone_manifest: [
      { project_id: project.id, project_name: project.name, project_full_name: project.full_name, path: "/workspace/#{project.full_name.tr('/', '-')}", token_identity: "project-token:#{project.github_token.name}" },
      { project_id: other_project.id, project_name: other_project.name, project_full_name: other_project.full_name, path: "/workspace/#{other_project.full_name.tr('/', '-')}", token_identity: "project-token:#{other_project.github_token.name}" }
    ])

    visit chat_session_path(session, format: :html)

    perform_enqueued_jobs do
      within("[data-chat-header='desktop']") { click_button "Reopen with workspace" }
    end

    expect(page).to have_text("Existing conversation")
    expect(page).to have_text("Workspace ready")
    expect(page).to have_text("/workspace/#{project.full_name.tr('/', '-')}")
    expect(page).to have_text("/workspace/#{other_project.full_name.tr('/', '-')}")
  end

  it "shows deleted-project reopen failures and keeps the rest usable" do
    session = create(:chat_session, :closed, :workspace, account:, created_by: user, container_capability: "stopped", container_id: nil)
    session.update!(clone_manifest: [
      { project_id: project.id, project_name: project.name, project_full_name: project.full_name, path: "/workspace/#{project.full_name.tr('/', '-')}", token_identity: "project-token:#{project.github_token.name}" },
      { project_id: other_project.id, project_name: other_project.name, project_full_name: other_project.full_name, path: "/workspace/#{other_project.full_name.tr('/', '-')}", token_identity: "project-token:#{other_project.github_token.name}" }
    ])
    other_project.destroy!

    visit chat_session_path(session, format: :html)

    perform_enqueued_jobs do
      within("[data-chat-header='desktop']") { click_button "Reopen with workspace" }
    end

    expect(page).to have_text("Workspace ready")
    expect(page).to have_text(other_project.full_name)
    expect(page).to have_text("could not be cloned")
    expect(page).to have_text("/workspace/#{project.full_name.tr('/', '-')}")
  end

  # Server-rendered capability indicator only. The broadcast-driven *in-place*
  # update (no reload) is exercised end-to-end by the ChatChannel broadcast
  # delivery specs — see spec/channels/chat_channel_spec.rb
  # (CHAT-SESSION-REOPEN-005). System specs fall back to rack_test (no JS) where
  # chromium is absent, so the in-place indicator flip cannot be asserted here.
  it "renders the persisted workspace capability on page load" do
    pending_session = create(:chat_session, :workspace, account:, created_by: user, container_capability: "pending")
    ready_session = create(:chat_session, :workspace, account:, created_by: user)

    visit chat_session_path(pending_session, format: :html)
    expect(page).to have_text("Workspace pending")

    visit chat_session_path(ready_session, format: :html)

    expect(page).to have_text("Workspace ready")
  end

  it "clones another project from the header affordance" do
    session = create(:chat_session, :workspace, account:, created_by: user)
    stub_clone_project_for(session, project)

    visit chat_session_path(session, format: :html)
    within("[data-chat-header='desktop']") do
      select project.name, from: "project_id"
      click_button "Clone into workspace"
    end

    expect(page).to have_text("/workspace/#{project.full_name.tr('/', '-')}")
    expect(page).to have_text("project-token:#{project.github_token.name}")
  end

  def clone_result(project)
    {
      "status" => "cloned",
      "project_id" => project.id,
      "project_slug" => project.full_name.tr("/", "-"),
      "repo_path" => "/workspace/#{project.full_name.tr('/', '-')}",
      "token_identity" => "project-token:#{project.github_token.name}"
    }
  end

  def stub_clone_project_for(session, project)
    tool = instance_double(Tools::CloneProject)
    allow(Tools::CloneProject).to receive(:new).and_return(tool)
    allow(tool).to receive(:call) do |project_id:, confirmed:|
      expect(project_id.to_s).to eq(project.id.to_s)
      expect(confirmed).to be(true)
      session.append_clone_manifest_entry(
        project_id: project.id,
        project_name: project.name,
        project_full_name: project.full_name,
        cloned_at: Time.current,
        path: "/workspace/#{project.full_name.tr('/', '-')}",
        token_identity: "project-token:#{project.github_token.name}",
        status: "ready",
        stale: false
      )
      session.save!
      clone_result(project)
    end
  end
end
