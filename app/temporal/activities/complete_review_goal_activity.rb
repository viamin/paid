# frozen_string_literal: true

module Activities
  class CompleteReviewGoalActivity < BaseActivity
    activity_name "CompleteReviewGoal"

    # Review-body marker is owned by Github::ReviewMarker so the proxy that
    # injects it and this reconciliation consumer can't drift apart.
    PAID_REVIEW_MARKER = Github::ReviewMarker::PAID_REVIEW_MARKER
    RECONCILIATION_LOG_LIMIT = 100

    def execute(input)
      agent_run_id = input[:agent_run_id]
      agent_run = AgentRun.find(agent_run_id)
      return result(agent_run) if agent_run.finished?

      track_phase(agent_run_id: agent_run_id, phase_key: "complete_review_goal", phase_group: "post", agent_run: agent_run) do
        reconciliation = agent_run.review_posted_at.blank? ? reconcile_posted_review(agent_run) : default_reconciliation_result

        if agent_run.review_posted_at.blank?
          fail_missing_review!(agent_run, **reconciliation)

          raise Temporalio::Error::ApplicationError.new(
            agent_run.error_message,
            type: reconciliation_error_type(reconciliation),
            non_retryable: true
          )
        end

        # Don't set pull_request_number for review runs — that field represents
        # the PR produced by the run. Review runs use source_pull_request_number
        # to track which PR was reviewed, keeping the two semantics distinct.
        completed = agent_run.complete!

        if completed
          agent_run.issue&.update!(review_goal_retry_count: 0) if agent_run.issue&.review_goal_retry_count&.positive?
          agent_run.log!("system", "Completed: review goal finished for PR ##{agent_run.source_pull_request_number}")

          logger.info(
            message: "agent_execution.review_goal_completed",
            agent_run_id: agent_run_id,
            pr_number: agent_run.source_pull_request_number,
            review_posted: agent_run.review_posted_at.present?
          )

          ProcessRunQueueJob.perform_later
        end

        result(agent_run.reload)
      end
    end

    private

    def result(agent_run)
      { agent_run_id: agent_run.id, success: agent_run.successful? }
    end

    # Returns the reviews found on GitHub during the run's window that were
    # NOT recognized as Paid-tracked (no marker, no logged review id). A
    # non-empty result after this method runs means a review does exist on
    # GitHub but bypassed Paid's tracking path — the exact ambiguity this
    # method exists to surface (#2779).
    def reconcile_posted_review(agent_run)
      candidates = candidate_reviews(agent_run)
      matches = candidates.select { |review| matching_review?(agent_run, review) }
      review = matches.max_by { |review| review[:submitted_at] }

      if review
        agent_run.update!(
          review_posted_at: review.fetch(:submitted_at),
          review_url: review_url(agent_run, review)
        )
        agent_run.log!("system", "Recovered tracked review from GitHub for PR ##{agent_run.source_pull_request_number}")

        logger.info(
          message: "agent_execution.review_goal_reconciled",
          agent_run_id: agent_run.id,
          pr_number: agent_run.source_pull_request_number,
          review_id: review[:id]
        )
        return default_reconciliation_result
      end

      { untracked_reviews: candidates, reconciliation_error: nil }
    rescue GithubClient::Error, Github::AppInstallation::Error => e
      logger.warn(
        message: "agent_execution.review_goal_reconciliation_failed",
        agent_run_id: agent_run.id,
        pr_number: agent_run.source_pull_request_number,
        error_class: e.class.name,
        error_message: e.message.to_s.truncate(500)
      )
      { untracked_reviews: [], reconciliation_error: e }
    end

    # All non-pending reviews submitted on GitHub during the run's window,
    # regardless of whether they carry the Paid marker or a logged review id.
    def candidate_reviews(agent_run)
      return [] unless agent_run.source_pull_request_number.present?

      reviews = agent_run.project.client&.pull_request_reviews(
        agent_run.project.full_name,
        agent_run.source_pull_request_number
      )
      Array(reviews).select do |review|
        review[:submitted_at].present? &&
          submitted_during_run?(agent_run, review[:submitted_at]) &&
          !review[:state].to_s.casecmp("PENDING").zero?
      end
    end

    def matching_review?(agent_run, review)
      paid_marked_review?(review) || agent_output_mentions_review_id?(agent_run, review)
    end

    def submitted_during_run?(agent_run, submitted_at)
      started_at = agent_run.started_at || agent_run.created_at
      submitted_at.between?(started_at - 1.minute, Time.current + 1.minute)
    end

    def paid_marked_review?(review)
      review[:body].to_s.include?(PAID_REVIEW_MARKER)
    end

    def agent_output_mentions_review_id?(agent_run, review)
      review_id = review[:id].to_s
      return false if review_id.blank?

      escaped_id = ActiveRecord::Base.sanitize_sql_like(review_id)
      recent_log_ids = agent_run.agent_run_logs
        .where(log_type: %w[stdout stderr])
        .recent
        .limit(RECONCILIATION_LOG_LIMIT)
        .select(:id)

      agent_run.agent_run_logs.where(id: recent_log_ids).where(
        "content LIKE ? OR content LIKE ? OR content LIKE ?",
        "%\"review_id\":#{escaped_id}%",
        "%\"review_id\": #{escaped_id}%",
        "%pullrequestreview-#{escaped_id}%"
      ).exists?
    end

    def review_url(agent_run, review)
      "https://github.com/#{agent_run.project.full_name}/pull/" \
        "#{agent_run.source_pull_request_number}#pullrequestreview-#{review.fetch(:id)}"
    end

    # Fails the run with a message that distinguishes "no tracked review" from
    # "no GitHub review exists" and, when available, cites what the
    # review-creation proxy POST actually did (attempted/timed out/upstream
    # error). This is the fix for #2779: a review can land on GitHub through a
    # path that bypasses proxy tracking, and the old message ("No review was
    # posted") made that look like the agent never reviewed at all.
    def default_reconciliation_result
      { untracked_reviews: [], reconciliation_error: nil }
    end

    def fail_missing_review!(agent_run, untracked_reviews:, reconciliation_error:)
      message = missing_review_message(agent_run, untracked_reviews:, reconciliation_error:)
      diagnostics = agent_run.review_proxy_diagnostics

      logger.warn(
        message: "agent_execution.review_goal_no_review_posted",
        agent_run_id: agent_run.id,
        pr_number: agent_run.source_pull_request_number,
        github_review_found: untracked_reviews.present?,
        github_review_check_failed: reconciliation_error.present?,
        github_review_check_error_class: reconciliation_error&.class&.name,
        github_review_check_error_message: reconciliation_error&.message&.to_s&.truncate(500),
        proxy_outcome: diagnostics["outcome"],
        proxy_http_status: diagnostics["http_status"],
        proxy_error_class: diagnostics["error_class"],
        proxy_error_message: diagnostics["error_message"]
      )

      agent_run.fail!(error: message)
    end

    def missing_review_message(agent_run, untracked_reviews:, reconciliation_error:)
      pr_ref = "PR ##{agent_run.source_pull_request_number}"
      return untracked_review_message(pr_ref, untracked_reviews) if untracked_reviews.present?
      return unverifiable_review_message(pr_ref, reconciliation_error, agent_run) if reconciliation_error.present?

      "No tracked review for #{pr_ref} and no GitHub review exists#{proxy_diagnostic_suffix(agent_run)}"
    end

    def untracked_review_message(pr_ref, untracked_reviews)
      review = untracked_reviews.max_by { |r| r[:submitted_at] }
      "No tracked review for #{pr_ref}, but a review exists on GitHub " \
        "(id=#{review[:id]}, state=#{review[:state]}) that Paid did not recognize as its own — " \
        "it likely bypassed the proxy tracking path."
    end

    def unverifiable_review_message(pr_ref, reconciliation_error, agent_run)
      "No tracked review for #{pr_ref}, and Paid could not verify whether GitHub has a review because " \
        "the review lookup failed (#{reconciliation_error.class}: #{reconciliation_error.message})" \
        "#{proxy_diagnostic_suffix(agent_run)}"
    end

    def reconciliation_error_type(reconciliation)
      return "ReviewUntracked" if reconciliation[:untracked_reviews].present?
      return "ReviewVerificationFailed" if reconciliation[:reconciliation_error].present?

      "ReviewNotPosted"
    end

    # Describes the review-creation proxy POST's latest known outcome for
    # this run, when available, so the failure is actionable without reading
    # raw logs. See Api::GithubProxyController#record_review_proxy_diagnostic.
    def proxy_diagnostic_suffix(agent_run)
      diagnostics = agent_run.review_proxy_diagnostics
      return "." if diagnostics.blank?

      case diagnostics["outcome"]
      when "timeout"
        " — the review-creation proxy POST timed out without a confirmed response from GitHub."
      when "connection_failed"
        " — the review-creation proxy POST failed to connect to GitHub."
      when "upstream_error"
        status = diagnostics["http_status"]
        " — the review-creation proxy POST returned an upstream error from GitHub#{" (HTTP #{status})" if status}."
      when "attempted"
        " — a review-creation proxy POST was attempted but no confirmation was recorded."
      else
        "."
      end
    end
  end
end
