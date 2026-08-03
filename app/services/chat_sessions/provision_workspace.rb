# frozen_string_literal: true

module ChatSessions
  # Central entry point for bringing a chat workspace container online so every
  # provisioning path honors the same reopen-restore contract.
  #
  # A resumed session that already recorded a clone manifest (its repos were
  # cloned into a previous workspace) is restored by replaying the manifest
  # rather than re-seeding only the primary project. This keeps the explicit
  # "Reopen with workspace" button (ProvisionContainerJob), the agent-loop lazy
  # provision (ToolDispatch), and the MCP tools/call lazy provision
  # (Tools::Registry) consistent: any of them brings the session back with every
  # recorded repo instead of some paths leaving it empty.
  #
  # Provision failures (image pull, daemon errors) propagate to the caller so it
  # can broadcast the terminal capability. On the reopen path the session stays
  # in the +provisioning+ capability while the manifest replays — it only flips
  # to +ready+ after restore succeeds, so the UI and server-side tool dispatch
  # never see a usable workspace before every recorded repo is back. A restore
  # failure is recovered here — resources reclaimed, the session returned to the
  # retryable stopped state, the user notified — and then re-raised as
  # RestoreFailed.
  class ProvisionWorkspace
    class Error < StandardError; end
    class RestoreFailed < Error; end

    attr_reader :chat_session

    def self.call(...)
      new(...).call
    end

    def initialize(chat_session:)
      @chat_session = chat_session
    end

    def call
      Containers::ProvisionForChat.call(chat_session:, seed_project: !reopen_restore?, ready: !reopen_restore?)
      restore_manifest! if reopen_restore?
      mark_ready! if reopen_restore?
    end

    private

    # A non-empty manifest means the session previously cloned repos into a
    # workspace; provisioning a fresh container must replay it rather than seed
    # only the primary project (which would discard the other cloned repos).
    def reopen_restore?
      chat_session.clone_manifest_entries.any?
    end

    # ProvisionForChat left the session in +provisioning+ for the reopen path so
    # neither the UI nor server-side tool dispatch treat it as usable while the
    # manifest replays. Restore has now succeeded, so it is safe to flip ready
    # and broadcast the capability change.
    def mark_ready!
      chat_session.update!(container_capability: "ready", container_ready_at: Time.current)
    end

    def restore_manifest!
      ChatSessions::RestoreCloneManifest.call(chat_session:)
    rescue StandardError => e
      recover_failed_restore!(e)
      raise RestoreFailed, e.message
    end

    # ProvisionForChat provisioned a running container with attached volumes but
    # (on the reopen path) left the capability at +provisioning+. A restore
    # failure must reclaim those resources so a retry provisions fresh ones,
    # surface the failure, and return the session to the stopped state (the only
    # state that offers a retry affordance) instead of leaving a provisioned but
    # empty workspace.
    def recover_failed_restore!(error)
      Containers::ChatSessionManager.new(chat_session).release_resources!
      persist_reopen_failure_notice!(error)
      chat_session.update!(container_capability: "stopped", container_id: nil, workspace_volume: nil, container_ready_at: nil)
      ChatSessions::BroadcastCapabilityState.call(chat_session: chat_session.reload)
    end

    def persist_reopen_failure_notice!(error)
      content = "Workspace reopen failed and could not be restored: #{error.message.to_s.truncate(300)}"
      existing = chat_session.messages.system.find_by("metadata ->> 'reopen_clone_failures' = 'true'")

      attributes = {
        role: "system",
        content: content,
        metadata: { "reopen_clone_failures" => true }
      }

      existing ? existing.update!(**attributes) : chat_session.messages.create!(**attributes)
    end
  end
end
