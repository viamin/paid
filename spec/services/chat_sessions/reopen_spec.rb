# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::Reopen do
  include ActiveJob::TestHelper

  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:) }
  let(:other_project) { create(:project, account:) }
  let(:container) { instance_double(Docker::Container, id: "restored-container") }
  let(:backend) { instance_double(Containers::Backends::Base) }

  before do
    ActiveJob::Base.queue_adapter = :test
    allow(Containers::ProvisionForChat).to receive(:call) do |chat_session:, **opts|
      # The reopen path defers the ready flip until restore completes, so the
      # stub must honor `ready:` to exercise the real ProvisionWorkspace flow.
      ready = opts.fetch(:ready, true)
      if ready
        chat_session.update!(container_capability: "ready", container_id: "restored-container", container_ready_at: Time.current)
      else
        chat_session.update!(container_capability: "provisioning", container_id: "restored-container")
      end
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
  end

  it "reopens a stopped workspace session and restores its clone manifest" do
    session = create(:chat_session, :closed, :workspace, account:, created_by: user, container_capability: "stopped", container_id: nil)
    session.messages.create!(role: "assistant", content: "Conversation still here")
    session.update!(
      clone_manifest: [
        {
          project_id: project.id,
          project_name: project.name,
          project_full_name: project.full_name,
          path: "/workspace/#{project.full_name.tr('/', '-')}",
          token_identity: "project-token:#{project.github_token.name}"
        }
      ]
    )

    perform_enqueued_jobs do
      described_class.call(chat_session: session)
    end

    expect(session.reload).to have_attributes(status: "active", container_capability: "ready", container_id: "restored-container")
    expect(session.metadata).to include("reopen_count" => 1)
    expect(session.messages.where(role: "assistant", content: "Conversation still here")).to exist
    expect(session.clone_manifest_entries.first).to include(status: "ready", stale: false)
  end

  it "clears any existing workspace contents before replaying the clone manifest" do
    session = create(:chat_session, :closed, :workspace, account:, created_by: user, container_capability: "stopped", container_id: nil)
    session.update!(clone_manifest: reopen_manifest(project))

    expect_workspace_reset
    expect_clone_restore(project)

    perform_enqueued_jobs do
      described_class.call(chat_session: session)
    end

    expect(session.reload.clone_manifest_entries.first).to include(status: "ready", stale: false)
  end

  it "keeps the session non-ready until the clone manifest finishes replaying" do
    session = create(:chat_session, :closed, :workspace, account:, created_by: user, container_capability: "stopped", container_id: nil)
    session.update!(clone_manifest: reopen_manifest(project))

    capability_during_restore = nil
    allow(ChatSessions::RestoreCloneManifest).to receive(:call) do |chat_session:|
      capability_during_restore = chat_session.container_capability
      []
    end

    perform_enqueued_jobs do
      described_class.call(chat_session: session)
    end

    # The session must stay non-ready while restore runs so neither the UI nor
    # server-side tool dispatch treat an empty workspace as usable.
    expect(capability_during_restore).to eq("provisioning")
    expect(session.reload.container_capability).to eq("ready")
    expect(session.reload.container_ready_at).to be_present
  end

  it "marks failed clones stale and persists a system notice naming them" do
    session = create(:chat_session, :closed, :workspace, account:, created_by: user, container_capability: "stopped", container_id: nil)
    session.update!(clone_manifest: reopen_manifest(project, other_project))
    other_project.destroy!

    perform_enqueued_jobs do
      described_class.call(chat_session: session)
    end

    stale_entry = session.reload.clone_manifest_entries.find { |entry| entry[:project_id] == other_project.id }
    expect(stale_entry).to include(status: "stale", stale: true, stale_reason: "project_missing")

    notice = session.messages.system.find_by("metadata ->> 'reopen_clone_failures' = 'true'")
    expect(notice.content).to include(other_project.full_name)
    expect(notice.content).to include("could not be cloned")
  end

  it "redacts clone tokens from reopen failure notices" do
    session = create(:chat_session, :closed, :workspace, account:, created_by: user, container_capability: "stopped", container_id: nil)
    session.update!(clone_manifest: reopen_manifest(project))
    stub_workspace_reset
    stub_clone_restore(project, result: [
      "",
      "fatal: repository 'https://x-access-token:#{project.github_token.token}@github.com/#{project.full_name}.git/' not found",
      128
    ])

    perform_enqueued_jobs do
      described_class.call(chat_session: session)
    end

    notice = session.reload.messages.system.find_by("metadata ->> 'reopen_clone_failures' = 'true'")
    expect(notice.content).to include("x-access-token:[REDACTED]@github.com")
    expect(notice.content).not_to include(project.github_token.token)
  end

  it "clears a stale reopen failure notice when a subsequent reopen restores every repo cleanly" do
    session = create(:chat_session, :closed, :workspace, account:, created_by: user, container_capability: "stopped", container_id: nil)
    session.messages.create!(role: "system", content: "previous reopen failures", metadata: { "reopen_clone_failures" => true, "failed_project_ids" => [ project.id ] })
    session.update!(clone_manifest: reopen_manifest(project))

    perform_enqueued_jobs do
      described_class.call(chat_session: session)
    end

    expect(session.reload.clone_manifest_entries.first).to include(status: "ready", stale: false)
    expect(session.messages.system.find_by("metadata ->> 'reopen_clone_failures' = 'true'")).to be_nil
  end

  it "restores an app-backed project through the same credential resolver as the original clone" do
    app_project = create(:project, :with_github_installation, account:)
    allow(Github::AppInstallation).to receive(:token_for).and_return("ghs_app_token")

    session = create(:chat_session, :closed, :workspace, account:, created_by: user, container_capability: "stopped", container_id: nil)
    session.update!(clone_manifest: reopen_manifest(app_project))
    clone_envs = capture_clone_env_tokens

    perform_enqueued_jobs do
      described_class.call(chat_session: session)
    end

    entry = session.reload.clone_manifest_entries.first
    expect(entry).to include(status: "ready", stale: false, stale_reason: nil)
    expect(entry[:token_identity]).to start_with("github-app:")
    expect(clone_envs).to include("CLONE_TOKEN=ghs_app_token")
  end

  it "is a no-op for an already-active workspace session" do
    session = create(:chat_session, :workspace, account:, created_by: user)

    expect {
      described_class.call(chat_session: session)
    }.not_to have_enqueued_job(ChatSessions::ProvisionContainerJob)

    expect(session.reload.container_capability).to eq("ready")
  end

  def reopen_manifest(*projects)
    projects.map do |manifest_project|
      {
        project_id: manifest_project.id,
        project_name: manifest_project.name,
        project_full_name: manifest_project.full_name,
        path: "/workspace/#{manifest_project.full_name.tr('/', '-')}",
        token_identity: manifest_token_identity(manifest_project)
      }
    end
  end

  def manifest_token_identity(project)
    if project.github_installation.present?
      "github-app:#{project.github_installation.github_installation_id}"
    else
      "project-token:#{project.github_token.name}"
    end
  end

  # Stubs exec_in_container to succeed while capturing every CLONE_TOKEN env
  # value passed to the container, so a test can assert which credential was used.
  def capture_clone_env_tokens
    envs = []
    allow(backend).to receive(:exec_in_container) do |*_args, **opts|
      envs.concat(Array(opts[:Env])) if opts.key?(:Env)
      [ [], [], 0 ]
    end
    envs
  end

  def workspace_reset_command
    [ "sh", "-c", "find /workspace -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +" ]
  end

  def clone_restore_command(project)
    [ "sh", "-c", "git clone --depth 1 https://x-access-token:$CLONE_TOKEN@github.com/#{project.full_name}.git /workspace/#{project.full_name.tr('/', '-')} 2>&1" ]
  end

  def clone_restore_options(project)
    {
      user: "agent",
      wait: account.tenant_setting&.chat_clone_timeout || ChatSessions::RestoreCloneManifest::CLONE_TIMEOUT,
      Env: [ "CLONE_TOKEN=#{project.github_token.token}" ]
    }
  end

  def expect_workspace_reset
    expect(backend).to receive(:exec_in_container)
      .with(container, workspace_reset_command, user: "agent", wait: ChatSessions::RestoreCloneManifest::WORKSPACE_RESET_TIMEOUT)
      .ordered
      .and_return([ "", "", 0 ])
  end

  def stub_workspace_reset
    allow(backend).to receive(:exec_in_container)
      .with(container, workspace_reset_command, user: "agent", wait: ChatSessions::RestoreCloneManifest::WORKSPACE_RESET_TIMEOUT)
      .and_return([ "", "", 0 ])
  end

  def expect_clone_restore(project)
    expect(backend).to receive(:exec_in_container)
      .with(container, clone_restore_command(project), clone_restore_options(project))
      .ordered
      .and_return([ "", "", 0 ])
  end

  def stub_clone_restore(project, result:)
    allow(backend).to receive(:exec_in_container)
      .with(container, clone_restore_command(project), clone_restore_options(project))
      .and_return(result)
  end
end
