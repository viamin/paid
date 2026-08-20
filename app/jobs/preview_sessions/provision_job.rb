# frozen_string_literal: true

require "tmpdir"

module PreviewSessions
  # @spec LIVE-PREVIEW-003
  class ProvisionJob < ApplicationJob
    include GoodJob::ActiveJobExtensions::Concurrency

    queue_as :low_priority
    self.perform_timeout = 10.minutes

    good_job_control_concurrency_with(
      total_limit: 1,
      enqueue_limit: 1,
      key: -> { "preview_sessions_provision_#{arguments.first}" }
    )

    discard_on ActiveRecord::RecordNotFound

    def perform(preview_session_id)
      preview_session = TenantContext.with_system_access do
        PreviewSession.includes(:project, :account, :created_by).find(preview_session_id)
      end
      return if preview_session.expired?
      return unless preview_session.pending? || preview_session.provisioning?

      TenantContext.with(preview_session.account) do
        provision_preview!(preview_session.reload)
      end
    end

    private

    def provision_preview!(preview_session)
      preview_session.with_lock do
        return unless preview_session.pending? || preview_session.provisioning?

        # Transition queued -> provisioning now that the worker has actually
        # picked the session up and is beginning real work. The session is
        # created as "pending" so the UI can show a distinct queued state while
        # waiting for a worker; it must not advertise provisioning before any
        # work has started.
        preview_session.mark_provisioning! if preview_session.pending?

        preview_session.agent_run ||= create_preview_agent_run!(preview_session)
        preview_session.save! if preview_session.changed?
      end

      agent_run = preview_session.agent_run
      provision = nil

      Dir.mktmpdir("paid-preview-session-#{preview_session.id}-") do |repo_path|
        provision = Previews::Provision.new(
          agent_run:,
          repo_path:,
          preview_session:,
          logger: Rails.logger
        )
        provision.call
      end

      # A concurrent stop may have flipped the session to a terminal state
      # while provision.call was running. If so, tear down the now-orphaned
      # container and tunnel so they don't leak, and transition the synthetic
      # agent run to a terminal status so it does not leak as an unfinished run.
      # Previews::Provision guards its own status writes against terminal
      # sessions, so the session is not resurrected to "ready".
      if preview_session.reload.terminal?
        provision&.cleanup!
        cancel_agent_run!(agent_run)
        return
      end

      complete_agent_run!(agent_run)
    rescue StandardError => e
      provision&.cleanup!
      mark_failed!(preview_session.reload, agent_run, e)
      raise
    end

    def create_preview_agent_run!(preview_session)
      AgentRun.create!(
        project: preview_session.project,
        initiating_user: preview_session.created_by,
        agent_type: "internal_agent",
        synthetic: true,
        external_metadata: AgentRun.preview_execution_metadata(
          preview_session: preview_session,
          granted_by: preview_session.created_by
        ),
        goal: "create_pr",
        custom_prompt: "Provision preview session #{preview_session.id} for #{preview_session.branch_name}",
        trigger_type: "manual",
        status: "running",
        branch_name: preview_session.branch_name,
        started_at: Time.current
      )
    end

    def complete_agent_run!(agent_run)
      agent_run.update!(
        status: "completed",
        completed_at: Time.current,
        duration_seconds: duration_seconds_for(agent_run)
      )
    end

    def cancel_agent_run!(agent_run)
      return unless agent_run
      return if agent_run.finished?

      agent_run.update!(
        status: "cancelled",
        completed_at: Time.current,
        duration_seconds: duration_seconds_for(agent_run)
      )
    end

    def mark_failed!(preview_session, agent_run, error)
      preview_session.mark_failed!(error.message) unless preview_session.failed? || preview_session.stopped?
      return unless agent_run

      agent_run.update!(
        status: "failed",
        error_message: error.message,
        completed_at: Time.current,
        duration_seconds: duration_seconds_for(agent_run)
      )
    end

    def duration_seconds_for(agent_run)
      [ (Time.current.to_f - agent_run.started_at.to_f).round, 0 ].max
    end
  end
end
