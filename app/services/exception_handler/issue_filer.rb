# frozen_string_literal: true

module ExceptionHandler
  # Creates a GitHub issue for a novel exception incident, or adds a comment
  # to an existing issue when a duplicate is detected with new context.
  class IssueFiler
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

      # Short lock to check-and-claim: prevents duplicate GitHub issues
      # when concurrent jobs process the same incident. The GitHub network
      # call happens outside the lock to avoid holding it during I/O.
      action = @incident.with_lock do
        if @incident.github_issue_number.present?
          :add_comment
        elsif @incident.action_taken == "filing"
          :wait_for_filing
        else
          @incident.update_column(:action_taken, "filing")
          :create_issue
        end
      end

      case action
      when :add_comment
        add_comment_to_existing(client: client)
      when :wait_for_filing
        wait_and_comment_or_retry(client: client)
      when :create_issue
        gh_issue = file_github_issue(client: client)
        # Re-lock to persist the issue number. If another worker raced
        # and already filed (e.g. stale "filing" retry), add a comment
        # instead of overwriting.
        @incident.with_lock do
          if @incident.github_issue_number.present?
            add_comment_to_existing(client: client)
          else
            persist_new_issue(gh_issue)
          end
        end
      end
    rescue GithubClient::Error => e
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

    def wait_and_comment_or_retry(client:)
      # Another worker claimed this incident. Wait briefly for it to
      # finish, then add a comment if it succeeded or retry if it stalled.
      sleep 2
      @incident.reload

      if @incident.github_issue_number.present?
        add_comment_to_existing(client: client)
      else
        # Previous claimant likely crashed — reclaim and file.
        gh_issue = file_github_issue(client: client)
        @incident.with_lock do
          if @incident.github_issue_number.present?
            add_comment_to_existing(client: client)
          else
            persist_new_issue(gh_issue)
          end
        end
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
      return unless @incident.github_issue_number

      client.add_comment(
        @project.full_name,
        @incident.github_issue_number,
        occurrence_comment
      )

      Rails.logger.info(
        message: "exception_handler.issue_comment_added",
        incident_id: @incident.id,
        issue_number: @incident.github_issue_number,
        occurrence_count: @incident.occurrence_count
      )
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
