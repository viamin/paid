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
    allow(backend).to receive(:exec_in_container).and_return([
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
        token_identity: "project-token:#{manifest_project.github_token.name}"
      }
    end
  end
end
