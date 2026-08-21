# frozen_string_literal: true

module Previews
  class Lifecycle
    # @spec LIVE-PREVIEW-003
    PREVIEW_CUSTOM_PROMPT = "Project preview session provisioning"
    ADVISORY_LOCK_SQL = "SELECT pg_advisory_lock($1, $2)".freeze
    ADVISORY_UNLOCK_SQL = "SELECT pg_advisory_unlock($1, $2)".freeze
    LOCK_NAMESPACE = 1_357_180_003

    class Error < StandardError
      attr_reader :preview_session

      def initialize(message, preview_session: nil)
        @preview_session = preview_session
        super(message)
      end
    end

    class << self
      def start!(...)
        new.start!(...)
      end

      def restart!(...)
        new.restart!(...)
      end

      def stop_project!(...)
        new.stop_project!(...)
      end

      def stop_session!(...)
        new.stop_session!(...)
      end
    end

    def start!(project:, branch_name:, created_by:)
      with_project_lock(project) do
        start_unlocked(project:, branch_name:, created_by:)
      end
    end

    def restart!(project:, branch_name:, created_by:)
      with_project_lock(project) do
        start_unlocked(project:, branch_name:, created_by:)
      end
    end

    def stop_project!(project:)
      with_project_lock(project) do
        stop_project_unlocked(project:)
      end
    end

    def stop_session!(preview_session:, terminal_status: "stopped")
      with_project_lock(preview_session.project) do
        stop_session_unlocked(preview_session:, terminal_status:)
      end
    end

    private

    def stop_project_unlocked(project:)
      sessions = PreviewSession.for_project(project).non_terminal.recent.to_a
      sessions.each do |preview_session|
        stop_session_unlocked(preview_session:, terminal_status: "stopped")
      end
      sessions.size
    end

    def stop_session_unlocked(preview_session:, terminal_status:)
      return false if preview_session.terminal? && terminal_status == "stopped"

      agent_run = preview_session.agent_run
      finalize_agent_run!(agent_run, terminal_status:)
      cleanup_service_dependencies!(agent_run)
      cleanup_container!(preview_session, agent_run)
      release_tunnel_port!(preview_session)
      remove_worktree!(agent_run)
      finalize_preview_session!(preview_session, terminal_status:)

      true
    rescue StandardError => e
      raise Error.new(e.message, preview_session: preview_session)
    end

    def start_unlocked(project:, branch_name:, created_by:)
      stop_project_unlocked(project:)

      preview_session = nil
      agent_run = nil
      repo_path = nil

      PreviewSession.transaction do
        preview_session = PreviewSession.build_for(
          project: project,
          branch_name: branch_name,
          created_by: created_by
        )
        preview_session.save!

        agent_run = create_preview_agent_run!(project:, created_by:, preview_session:)
        preview_session.update!(agent_run:)
      end

      repo_path = WorktreeService.new(project).create_worktree(agent_run)
      provision_preview!(preview_session:, agent_run:, repo_path:)
      preview_session.reload
    rescue StandardError => e
      raise if e.is_a?(Error)

      cleanup_failed_start(
        preview_session: preview_session,
        agent_run: agent_run,
        error_message: e.message
      )
      raise Error.new(e.message, preview_session: preview_session)
    end

    def create_preview_agent_run!(project:, created_by:, preview_session:)
      AgentRun.create!(
        project: project,
        initiating_user: created_by,
        agent_type: "internal_agent",
        goal: "create_pr",
        custom_prompt: PREVIEW_CUSTOM_PROMPT,
        external_metadata: AgentRun.preview_execution_metadata(
          preview_session: preview_session,
          granted_by: created_by
        ),
        trigger_type: "manual",
        status: "running",
        started_at: Time.current
      )
    end

    def provision_preview!(preview_session:, agent_run:, repo_path:)
      provision = Previews::Provision.new(
        agent_run: agent_run,
        repo_path: repo_path,
        preview_session: preview_session,
        logger: Rails.logger
      )
      provision.call
    end

    def cleanup_failed_start(preview_session:, agent_run:, error_message:)
      finalize_agent_run!(agent_run, terminal_status: "failed", error_message:)
      cleanup_service_dependencies!(agent_run)
      cleanup_container!(preview_session, agent_run)
      release_tunnel_port!(preview_session)
      remove_worktree!(agent_run)
      finalize_preview_session!(preview_session, terminal_status: "failed", error_message:)
    rescue StandardError => e
      Rails.logger.warn(
        message: "previews.lifecycle.failed_start_cleanup_failed",
        preview_session_id: preview_session&.id,
        agent_run_id: agent_run&.id,
        error: e.message
      )
      preview_session&.update!(status: "failed", error_message: error_message, tunnel_port: nil)
    end

    def finalize_agent_run!(agent_run, terminal_status:, error_message: nil)
      return unless agent_run&.persisted?
      return if agent_run.status.in?(AgentRun::FINISHED_STATUSES)

      attributes = {
        status: terminal_status == "failed" ? "failed" : "cancelled",
        completed_at: Time.current,
        duration_seconds: duration_seconds_for(agent_run),
        service_container_ids: [],
        service_environment: {}
      }
      attributes[:error_message] = error_message if terminal_status == "failed"
      agent_run.update!(attributes)
    end

    def duration_seconds_for(agent_run)
      return 0 if agent_run.started_at.blank?

      [ (Time.current - agent_run.started_at).to_i, 0 ].max
    end

    def cleanup_service_dependencies!(agent_run)
      return unless agent_run&.persisted?

      Previews::Provision.release_baseline(agent_run)
      service_container_ids = Array(agent_run.service_container_ids_before_last_save.presence || agent_run.service_container_ids)
      service_environment = agent_run.service_environment_before_last_save.presence || agent_run.service_environment
      return if service_container_ids.empty?

      Containers::ServiceProvisioner.new.cleanup_service_containers(
        service_container_ids,
        agent_run: agent_run,
        service_environment: service_environment || {}
      )
    rescue StandardError => e
      Rails.logger.warn(
        message: "previews.lifecycle.service_cleanup_failed",
        agent_run_id: agent_run.id,
        error: e.message
      )
    end

    def cleanup_container!(preview_session, agent_run)
      return if preview_session.container_id.blank? || agent_run.blank? || agent_run.worktree_path.blank?

      Containers::Provision.reconnect(
        agent_run: agent_run,
        container_id: preview_session.container_id,
        worktree_path: agent_run.worktree_path
      ).cleanup(force: true)
    rescue Containers::Provision::ProvisionError, Docker::Error::DockerError => e
      Rails.logger.warn(
        message: "previews.lifecycle.container_cleanup_failed",
        preview_session_id: preview_session.id,
        agent_run_id: agent_run.id,
        error: e.message
      )
    end

    def release_tunnel_port!(preview_session)
      return if preview_session.tunnel_port.blank?

      Previews::TunnelManager.new(preview_session:, logger: Rails.logger).release_port!
    rescue StandardError => e
      Rails.logger.warn(
        message: "previews.lifecycle.tunnel_release_failed",
        preview_session_id: preview_session.id,
        error: e.message
      )
    end

    def remove_worktree!(agent_run)
      return unless agent_run&.persisted?

      WorktreeService.new(agent_run.project).remove_worktree(agent_run)
    rescue StandardError => e
      Rails.logger.warn(
        message: "previews.lifecycle.worktree_cleanup_failed",
        agent_run_id: agent_run.id,
        error: e.message
      )
    end

    def finalize_preview_session!(preview_session, terminal_status:, error_message: nil)
      return unless preview_session&.persisted?

      attributes = { tunnel_port: nil }
      if terminal_status == "failed"
        attributes[:status] = "failed"
        attributes[:error_message] = error_message
      else
        attributes[:status] = "stopped"
        attributes[:error_message] = nil
      end

      preview_session.update!(attributes)
    end

    def with_project_lock(project)
      connection = ActiveRecord::Base.connection
      lock_key = project.id % 2_147_483_647
      raw_connection = connection.raw_connection
      raw_connection.exec_params(ADVISORY_LOCK_SQL, [ LOCK_NAMESPACE, lock_key ])
      yield
    ensure
      raw_connection&.exec_params(ADVISORY_UNLOCK_SQL, [ LOCK_NAMESPACE, lock_key ])
    end
  end
end
