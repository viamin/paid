# frozen_string_literal: true

module Issues
  # Enforces the human GitHub allowlist on externally initiated issue changes.
  class EnforceMutationTrust
    UNTRUSTED_MUTATION_COMMENT = <<~COMMENT.strip.freeze
      Paid automatically closed this issue because the GitHub account that changed it is not on this project's trusted GitHub user allowlist. A repository owner or Paid account administrator can add the account to the trusted users list and then reopen or edit the issue. If you believe this was in error, please contact a repository owner.
    COMMENT

    def self.call(...)
      new(...).call
    end

    def initialize(project:, action:, issue_number:, actor_login:)
      @project = project
      @action = action
      @issue_number = issue_number
      @actor_login = actor_login
    end

    # @spec GITHUB-SYNC-013
    def call
      return allow_paid_mutation! if paid_originated?
      return allow! if trusted?

      close!
    end

    private

    attr_reader :project, :action, :issue_number, :actor_login

    def allow!
      record!(decision: "allow")
      log!(decision: "allow")
      :allowed
    end

    def allow_paid_mutation!
      record!(decision: "allow_paid_mutation")
      log!(decision: "allow_paid_mutation")
      :allowed
    end

    def close!
      client.update_issue(project.full_name, issue_number, state: "closed")
      client.add_comment(project.full_name, issue_number, UNTRUSTED_MUTATION_COMMENT)
      record!(decision: "close")
      log!(decision: "close")
      :closed
    end

    def trusted?
      project.trusted_github_user?(actor_login)
    end

    # A signed webhook sender matching this App's bot identity proves the
    # mutation originated through Paid's project credential. This is distinct
    # from human allowlist trust, which remains false for the bot.
    def paid_originated?
      project.paid_bot_author?(actor_login)
    end

    def client
      project.client || raise(ArgumentError, "Project has no GitHub credential configured")
    end

    def record!(decision:)
      Audit::RecordEvent.call(
        action: "issue.mutation_trust_verified",
        subject: project,
        metadata: { issue_number:, actor_login:, action:, trusted: trusted?, paid_originated: paid_originated?, decision: }
      )
    end

    def log!(decision:)
      Rails.logger.info(
        message: "issue_mutation_trust.#{decision}",
        project_id: project.id,
        issue_number: issue_number,
        actor_login: actor_login,
        trusted: trusted?,
        paid_originated: paid_originated?,
        action: action,
        decision: decision
      )
    end
  end
end
