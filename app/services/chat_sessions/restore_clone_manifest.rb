# frozen_string_literal: true

require "shellwords"

module ChatSessions
  class RestoreCloneManifest
    CLONE_TIMEOUT = 120
    WORKSPACE_RESET_TIMEOUT = 30

    attr_reader :chat_session

    def self.call(...)
      new(...).call
    end

    def initialize(chat_session:)
      @chat_session = chat_session
    end

    def call
      reset_workspace! if chat_session.clone_manifest_entries.any?

      failures = chat_session.clone_manifest_entries.filter_map { |entry| restore_entry(entry) }
      sync_failure_notice!(failures)
      failures
    end

    private

    def reset_workspace!
      result = Containers.backend.exec_in_container(
        Containers.backend.get_container(chat_session.container_id),
        [ "sh", "-c", "find /workspace -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +" ],
        user: "agent",
        wait: WORKSPACE_RESET_TIMEOUT
      )

      return if result.is_a?(Array) && result[2].to_i.zero?

      output = result.is_a?(Array) ? result[0..1].flatten.join("\n").presence || "workspace reset failed" : "workspace reset failed"
      raise "Workspace reset failed: #{output.truncate(300)}"
    end

    def restore_entry(entry)
      project = project_for_entry(entry)
      return mark_stale(entry, "project_missing", "Project is no longer available") unless project

      resolved = TenantContext.with(chat_session.account) { resolve_clone_credential(project) }
      return mark_stale(entry, "token_missing", "Project no longer has an active GitHub credential") unless resolved

      token = resolved.credential
      repo_path = entry[:path].presence || "/workspace/#{project.full_name.tr('/', '-')}"
      clone_cmd = "git clone --depth 1 https://x-access-token:$CLONE_TOKEN@github.com/#{Shellwords.escape(project.full_name)}.git #{Shellwords.escape(repo_path)} 2>&1"
      result = Containers.backend.exec_in_container(
        Containers.backend.get_container(chat_session.container_id),
        [ "sh", "-c", clone_cmd ],
        user: "agent",
        wait: chat_session.account.tenant_setting&.chat_clone_timeout || CLONE_TIMEOUT,
        Env: [ "CLONE_TOKEN=#{token}" ]
      )

      exit_code = result.is_a?(Array) ? result[2].to_i : -1
      return clear_stale(entry, project, resolved.identity) if exit_code.zero?

      output = clone_failure_output(result, token)
      mark_stale(entry, "clone_failed", output)
    rescue Docker::Error::DockerError => e
      mark_stale(entry, "clone_failed", redact_clone_output(e.message, token))
    end

    def project_for_entry(entry)
      TenantContext.with_system_access do
        Project.find_by(id: entry[:project_id])
          &.then { |project| project if project.account_id == chat_session.account_id }
      end
    end

    # Reuses the same credential-resolution path as Tools::CloneProject so a
    # repo cloned via a GitHub App installation or a user-scoped token is
    # restored with an equivalent credential instead of requiring project.github_token.
    def resolve_clone_credential(project)
      Tools::RepoReadClientResolver.new(project:, user: chat_session.created_by, session: chat_session).resolve
    rescue ArgumentError
      nil
    end

    def clear_stale(entry, project, identity)
      chat_session.replace_clone_manifest_entry(project_id: entry[:project_id], attributes: {
        "project_name" => project.name,
        "project_full_name" => project.full_name,
        "token_identity" => identity.presence || entry[:token_identity].presence || project.github_token&.name,
        "status" => "ready",
        "stale" => false,
        "stale_reason" => nil,
        "stale_at" => nil
      })
      chat_session.save!
      nil
    end

    def mark_stale(entry, reason, detail)
      chat_session.replace_clone_manifest_entry(project_id: entry[:project_id], attributes: {
        "status" => "stale",
        "stale" => true,
        "stale_reason" => reason,
        "stale_at" => Time.current.iso8601
      })
      chat_session.save!

      {
        project_id: entry[:project_id].to_i,
        project_name: entry[:project_full_name].presence || entry[:project_name].presence || "Project ##{entry[:project_id]}",
        detail: detail
      }
    end

    def sync_failure_notice!(failures)
      existing_notice = chat_session.messages.system.find_by("metadata ->> 'reopen_clone_failures' = 'true'")

      if failures.empty?
        existing_notice&.destroy!
        return
      end

      lines = failures.map { |failure| "- #{failure[:project_name]}: #{failure[:detail]}" }
      content = [
        "Workspace reopen restored the conversation, but some repos could not be cloned:",
        *lines
      ].join("\n")

      attributes = {
        role: "system",
        content: content,
        metadata: {
          "reopen_clone_failures" => true,
          "failed_project_ids" => failures.map { |failure| failure[:project_id] }
        }
      }

      existing_notice ? existing_notice.update!(**attributes) : chat_session.messages.create!(**attributes)
    end

    def clone_failure_output(result, token)
      raw_output = result.is_a?(Array) ? result[0..1].flatten.join("\n") : "clone command failed"
      redact_clone_output(raw_output, token).truncate(300)
    end

    def redact_clone_output(output, token)
      redacted = output.to_s.dup
      redacted.gsub!(token, "[REDACTED]") if token.present?
      redacted.gsub!(%r{x-access-token:[^@/\s]+@github\.com}, "x-access-token:[REDACTED]@github.com")
      redacted
    end
  end
end
