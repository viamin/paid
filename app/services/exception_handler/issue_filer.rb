# frozen_string_literal: true

module ExceptionHandler
  # Creates a GitHub issue for a novel exception incident, or adds a comment
  # to an existing issue when a duplicate is detected with new context.
  class IssueFiler
    class RetryableFilingInProgress < StandardError; end

    CLAIM_STALE_AFTER = 5.minutes

    def self.call(incident:, project:)
      new(incident: incident, project: project).call
    end

    def initialize(incident:, project:)
      @incident = incident
      @project = project
    end

    def call
      client = @project&.github_token&.client
      return unless client

      case action
      when :add_comment
        add_comment_to_existing(client: client)
      when :create_issue
        create_issue_with_claim(client: client)
      when :wait_for_filing
        wait_for_filing_resolution(client: client)
      end
    rescue GithubClient::Error => e
      release_claim!
      Rails.logger.warn(
        message: "exception_handler.issue_filing_failed",
        incident_id: @incident.id,
        error: e.message
      )
      nil
    rescue ActiveRecord::RecordNotFound
      Rails.logger.warn(
        message: "exception_handler.incident_gone",
        incident_id: @incident.id
      )
      nil
    end

    private

    def action
      @incident.with_lock do
        @incident.reload

        return :add_comment if github_issue_recorded?
        return :wait_for_filing if filing_claim_active?

        claim_incident!
        :create_issue
      end
    end

    def wait_for_filing_resolution(client:)
      case action
      when :add_comment
        add_comment_to_existing(client: client)
      when :create_issue
        create_issue_with_claim(client: client)
      else
        raise RetryableFilingInProgress, "GitHub issue filing already in progress for incident #{@incident.id}"
      end
    end

    def create_issue_with_claim(client:)
      gh_issue = file_github_issue(client: client)
      # Re-lock to persist the issue number. If another worker reclaimed a
      # stale filing state or the original claimant completed first, comment
      # on the existing issue instead of overwriting it.
      @incident.with_lock do
        @incident.reload

        if github_issue_recorded?
          add_comment_to_existing(client: client)
        else
          persist_new_issue(gh_issue)
        end
      end
    end

    def claim_incident!
      @incident.update_columns(action_taken: "filing", updated_at: Time.current)
    end

    def filing_claim_active?
      @incident.action_taken == "filing" && !filing_claim_stale?
    end

    def filing_claim_stale?
      @incident.updated_at < CLAIM_STALE_AFTER.ago
    end

    def release_claim!
      @incident.with_lock do
        @incident.reload
        return if github_issue_recorded?
        return unless @incident.action_taken == "filing"

        @incident.update_columns(action_taken: "notified", updated_at: Time.current)
      end
    end

    def file_github_issue(client:)
      client.create_issue(
        @project.full_name,
        title: issue_title,
        body: issue_body,
        labels: issue_labels
      )
    end

    def persist_new_issue(gh_issue)
      @incident.update!(
        github_issue_url: gh_issue.html_url,
        github_issue_number: gh_issue.number,
        project: @project,
        action_taken: "issue_filed"
      )

      Rails.logger.info(
        message: "exception_handler.issue_created",
        incident_id: @incident.id,
        issue_url: gh_issue.html_url
      )

      gh_issue.html_url
    end

    def add_comment_to_existing(client:)
      issue_number = existing_github_issue_number
      return unless issue_number

      client.add_comment(
        @project.full_name,
        issue_number,
        occurrence_comment
      )

      Rails.logger.info(
        message: "exception_handler.issue_comment_added",
        incident_id: @incident.id,
        issue_number:,
        occurrence_count: @incident.occurrence_count
      )
    end

    def existing_github_issue_number
      @incident.github_issue_number || github_issue_number_from_url
    end

    def github_issue_recorded?
      @incident.github_issue_url.present? || existing_github_issue_number.present?
    end

    def github_issue_number_from_url
      issue_url = @incident.github_issue_url.to_s
      match = issue_url.match(%r{/issues/(\d+)(?:[/?#]|$)})
      match&.captures&.first&.to_i
    end

    def issue_title
      "[#{@incident.severity.upcase}] #{@incident.subsystem}: #{@incident.exception_class}".truncate(255)
    end

    def issue_body
      <<~BODY.strip
        ## Exception Incident

        **Subsystem:** #{@incident.subsystem}
        **Severity:** #{@incident.severity.upcase}
        **Exception:** `#{@incident.exception_class}`
        **First seen:** #{@incident.created_at&.iso8601 || Time.current.iso8601}

        ### Message
        ```
        #{@incident.message.truncate(2000)}
        ```

        ### Backtrace
        ```
        #{@incident.backtrace.to_s.truncate(3000)}
        ```

        ### Context
        ```json
        #{JSON.pretty_generate(@incident.context).truncate(2000)}
        ```

        ---
        *Filed automatically by Paid exception handler.*
      BODY
    end

    def issue_labels
      labels = [ @incident.severity.upcase, "exception", @incident.subsystem ]
      labels.compact_blank
    end

    def occurrence_comment
      <<~COMMENT.strip
        **Occurrence ##{@incident.occurrence_count}** at #{@incident.last_occurred_at.iso8601}

        This exception has recurred. Current count: #{@incident.occurrence_count}.

        ### Latest context
        ```json
        #{JSON.pretty_generate(@incident.context.fetch("latest_occurrence", {})).truncate(1000)}
        ```
      COMMENT
    end
  end
end
