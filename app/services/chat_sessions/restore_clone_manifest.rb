# frozen_string_literal: true

require "shellwords"

module ChatSessions
  class RestoreCloneManifest
    CLONE_TIMEOUT = 120

    attr_reader :chat_session

    def self.call(...)
      new(...).call
    end

    def initialize(chat_session:)
      @chat_session = chat_session
    end

    def call
      failures = chat_session.clone_manifest_entries.filter_map { |entry| restore_entry(entry) }
      persist_failure_notice!(failures) if failures.any?
      failures
    end

    private

    def restore_entry(entry)
      project = Project.find_by(id: entry[:project_id])
      return mark_stale(entry, "project_missing", "Project is no longer available") unless project

      github_token = project.github_token
      return mark_stale(entry, "token_missing", "Project no longer has an active GitHub token") unless github_token&.active?

      repo_path = entry[:path].presence || "/workspace/#{project.full_name.tr('/', '-')}"
      clone_cmd = "git clone --depth 1 https://x-access-token:$CLONE_TOKEN@github.com/#{Shellwords.escape(project.full_name)}.git #{Shellwords.escape(repo_path)} 2>&1"
      result = Containers.backend.exec_in_container(
        Containers.backend.get_container(chat_session.container_id),
        [ "sh", "-c", clone_cmd ],
        user: "agent",
        wait: chat_session.account.tenant_setting&.chat_clone_timeout || CLONE_TIMEOUT,
        Env: [ "CLONE_TOKEN=#{github_token.token}" ]
      )

      exit_code = result.is_a?(Array) ? result[2].to_i : -1
      return clear_stale(entry, project) if exit_code.zero?

      output = clone_failure_output(result, github_token.token)
      mark_stale(entry, "clone_failed", output)
    rescue Docker::Error::DockerError => e
      mark_stale(entry, "clone_failed", redact_clone_output(e.message, github_token&.token))
    end

    def clear_stale(entry, project)
      chat_session.replace_clone_manifest_entry(project_id: entry[:project_id], attributes: {
        "project_name" => project.name,
        "project_full_name" => project.full_name,
        "token_identity" => entry[:token_identity].presence || project.github_token&.name,
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

    def persist_failure_notice!(failures)
      lines = failures.map { |failure| "- #{failure[:project_name]}: #{failure[:detail]}" }
      content = [
        "Workspace reopen restored the conversation, but some repos could not be cloned:",
        *lines
      ].join("\n")

      existing_notice = chat_session.messages.system.find_by("metadata ->> 'reopen_clone_failures' = 'true'")
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
