# frozen_string_literal: true

require "rails_helper"

# @spec LIVE-PREVIEW-003
RSpec.describe Previews::Lifecycle do
  let(:project) { create(:project, default_branch: "main") }
  let(:user) { create(:user, account: project.account) }
  let(:repo_path) { "/tmp/paid-preview-worktree" }
  let(:worktree_service) { instance_double(WorktreeService, create_worktree: repo_path, remove_worktree: true) }
  let(:provision) { instance_double(Previews::Provision) }
  let(:provision_result) do
    Previews::Provision::Result.new(
      container_service: nil,
      config: nil,
      network_name: "paid-preview",
      service_environment: { "DATABASE_URL" => "postgres://preview" },
      service_container_ids: [ 101, 202 ],
      seed_data: {},
      tunnel_port: 8242,
      tunnel_token: "preview-token"
    )
  end
  let(:reconnected_container) { instance_double(Containers::Provision, cleanup: true) }
  let(:service_provisioner) { instance_double(Containers::ServiceProvisioner, cleanup_service_containers: true) }
  let(:tunnel_manager) { instance_double(Previews::TunnelManager, release_port!: true) }

  before do
    allow(WorktreeService).to receive(:new).with(project).and_return(worktree_service)
    allow(worktree_service).to receive(:create_worktree) do |agent_run|
      agent_run.update!(
        worktree_path: repo_path,
        branch_name: "paid/paid-agent-#{agent_run.id}",
        base_commit_sha: "0123456789abcdef0123456789abcdef01234567"
      )
      repo_path
    end
    allow(Previews::Provision).to receive(:new).and_return(provision)
    allow(provision).to receive(:call) do
      session = project.preview_sessions.recent.first
      session.update!(status: "ready", tunnel_port: 8242, container_id: "container-live")
      session.agent_run.update!(
        service_container_ids: [ 101, 202 ],
        service_environment: { "DATABASE_URL" => "postgres://preview" }
      )
      provision_result
    end
    allow(Containers::Provision).to receive(:reconnect).and_return(reconnected_container)
    allow(Containers::ServiceProvisioner).to receive(:new).and_return(service_provisioner)
    allow(Previews::TunnelManager).to receive(:new).and_return(tunnel_manager)
  end

  describe ".start!" do
    it "creates a live preview session backed by a running agent run and worktree" do
      session = described_class.start!(project:, branch_name: "feature/live-preview", created_by: user)
      agent_run = session.agent_run

      expect_preview_session(session)
      expect_preview_agent_run(agent_run)
      expect_provision_to_have_started_for(session, agent_run)
    end

    it "fails the preview session and cleans up partial resources when provisioning fails" do
      stub_failed_preview_provision_with_overlap_state
      expect_overlap_state_to_be_released_before_cleanup

      expect {
        described_class.start!(project:, branch_name: "feature/broken-preview", created_by: user)
      }.to raise_error(described_class::Error, /preview boot failed/)

      session = project.preview_sessions.recent.first
      expect(session).to be_failed
      expect(session.error_message).to eq("preview boot failed")
      expect(session.tunnel_port).to be_nil

      agent_run = session.agent_run
      expect(agent_run.reload.status).to eq("failed")
      expect(agent_run.error_message).to eq("preview boot failed")
      expect(PreviewProvisionState.find_by(agent_run: agent_run)).to be_nil
      expect(worktree_service).to have_received(:remove_worktree).with(agent_run)
    end

    it "holds a project advisory lock for the full startup flow" do
      raw_connection = instance_double(PG::Connection, exec_params: true)
      connection = ActiveRecord::Base.connection
      allow(connection).to receive(:raw_connection).and_return(raw_connection)
      lock_key = project.id % 2_147_483_647

      described_class.start!(project:, branch_name: "feature/live-preview", created_by: user)

      expect(raw_connection).to have_received(:exec_params)
        .with("SELECT pg_advisory_lock($1, $2)", [ described_class::LOCK_NAMESPACE, lock_key ]).once
      expect(raw_connection).to have_received(:exec_params)
        .with("SELECT pg_advisory_unlock($1, $2)", [ described_class::LOCK_NAMESPACE, lock_key ]).once
    end
  end

  describe ".restart!" do
    it "tears down the previous live session before provisioning a new one" do
      previous_run = create_existing_preview_agent_run
      previous = create_existing_preview_session(previous_run)

      current = described_class.restart!(project:, branch_name: "feature/next", created_by: user)

      expect_restarted_preview(previous, current)
      expect_existing_preview_resources_to_be_cleaned_up(previous_run)
    end
  end

  describe ".stop_session!" do
    it "tears down preview resources, clears the tunnel association, and finalizes the agent run" do
      agent_run = create_existing_preview_agent_run(service_container_ids: [ 101, 202 ], database_url: "postgres://preview")
      session = create_existing_preview_session(agent_run, branch_name: "feature/live-preview", tunnel_port: 8242,
        container_id: "container-live")
      PreviewProvisionState.create!(agent_run: agent_run, active_count: 1)
      expect_overlap_state_to_be_released_before_cleanup

      described_class.stop_session!(preview_session: session)

      expect_stopped_preview_session(session)
      expect_stopped_preview_agent_run(agent_run)
      expect_preview_resources_to_be_cleaned_up(agent_run, [ 101, 202 ], "postgres://preview")
      expect(PreviewProvisionState.find_by(agent_run: agent_run)).to be_nil
    end
  end

  def expect_overlap_state_to_be_released_before_cleanup
    allow(service_provisioner).to receive(:cleanup_service_containers) do |_, agent_run:, **|
      expect(PreviewProvisionState.find_by(agent_run: agent_run)).to be_nil
    end
  end

  def stub_failed_preview_provision_with_overlap_state
    allow(provision).to receive(:call) do
      session = project.preview_sessions.recent.first
      session.agent_run.update!(
        service_container_ids: [ 101, 202 ],
        service_environment: { "DATABASE_URL" => "postgres://preview" }
      )
      PreviewProvisionState.create!(agent_run: session.agent_run, active_count: 1)
      raise "preview boot failed"
    end
  end

  def expect_preview_session(session)
    aggregate_failures do
      expect(session.status).to eq("ready")
      expect(session.branch_name).to eq("feature/live-preview")
      expect(session.tunnel_port).to eq(8242)
      expect(session.container_id).to eq("container-live")
    end
  end

  def expect_preview_agent_run(agent_run)
    aggregate_failures do
      expect(agent_run).to be_present
      expect(agent_run.status).to eq("running")
      expect(agent_run.branch_name).to match(%r{\Apaid/paid-agent-})
      expect(agent_run.worktree_path).to eq(repo_path)
      expect(agent_run.custom_prompt).to eq("Project preview session provisioning")
      expect(agent_run.external_metadata).to include("preview_session" => true)
    end
  end

  def expect_provision_to_have_started_for(session, agent_run)
    aggregate_failures do
      expect(worktree_service).to have_received(:create_worktree).with(agent_run)
      expect(Previews::Provision).to have_received(:new).with(
        agent_run: agent_run,
        repo_path: repo_path,
        preview_session: session,
        logger: Rails.logger
      )
      expect(provision).to have_received(:call)
    end
  end

  def create_existing_preview_agent_run(service_container_ids: [ 777 ], database_url: "postgres://old-preview")
    create(:agent_run, :running, :with_custom_prompt, project: project, worktree_path: repo_path).tap do |agent_run|
      agent_run.update!(
        service_container_ids: service_container_ids,
        service_environment: { "DATABASE_URL" => database_url }
      )
    end
  end

  def create_existing_preview_session(agent_run, branch_name: "feature/previous", tunnel_port: 8241, container_id: "container-previous")
    create(
      :preview_session,
      :ready,
      project: project,
      branch_name: branch_name,
      tunnel_port: tunnel_port,
      container_id: container_id,
      created_by: user,
      agent_run: agent_run
    )
  end

  def expect_restarted_preview(previous, current)
    aggregate_failures do
      expect(previous.reload.status).to eq("stopped")
      expect(previous.tunnel_port).to be_nil
      expect(current.id).not_to eq(previous.id)
      expect(current.branch_name).to eq("feature/next")
    end
  end

  def expect_existing_preview_resources_to_be_cleaned_up(previous_run)
    aggregate_failures do
      expect(reconnected_container).to have_received(:cleanup).with(force: true)
      expect(service_provisioner).to have_received(:cleanup_service_containers).with(
        [ 777 ],
        agent_run: previous_run,
        service_environment: { "DATABASE_URL" => "postgres://old-preview" }
      )
    end
  end

  def expect_stopped_preview_session(session)
    aggregate_failures do
      expect(session.reload.status).to eq("stopped")
      expect(session.tunnel_port).to be_nil
    end
  end

  def expect_stopped_preview_agent_run(agent_run)
    aggregate_failures do
      expect(agent_run.reload.status).to eq("cancelled")
      expect(agent_run.service_container_ids).to eq([])
      expect(agent_run.service_environment).to eq({})
    end
  end

  def expect_preview_resources_to_be_cleaned_up(agent_run, service_container_ids, database_url)
    aggregate_failures do
      expect(reconnected_container).to have_received(:cleanup).with(force: true)
      expect(service_provisioner).to have_received(:cleanup_service_containers).with(
        service_container_ids,
        agent_run: agent_run,
        service_environment: { "DATABASE_URL" => database_url }
      )
      expect(tunnel_manager).to have_received(:release_port!)
      expect(worktree_service).to have_received(:remove_worktree).with(agent_run)
    end
  end
end
