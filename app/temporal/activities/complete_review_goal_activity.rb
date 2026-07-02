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
        reconcile_posted_review(agent_run) if agent_run.review_posted_at.blank?

        if agent_run.review_posted_at.blank?
          logger.warn(
            message: "agent_execution.review_goal_no_review_posted",
            agent_run_id: agent_run_id,
            pr_number: agent_run.source_pull_request_number
          )
          agent_run.fail!(error: "No review was posted on PR ##{agent_run.source_pull_request_number}")

          raise Temporalio::Error::ApplicationError.new(
            "No review was posted on PR ##{agent_run.source_pull_request_number}",
            type: "ReviewNotPosted",
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

    def reconcile_posted_review(agent_run)
      review = matching_review(agent_run)
      return unless review

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
    rescue GithubClient::Error, Github::AppInstallation::Error => e
      logger.warn(
        message: "agent_execution.review_goal_reconciliation_failed",
        agent_run_id: agent_run.id,
        pr_number: agent_run.source_pull_request_number,
        error_class: e.class.name,
        error_message: e.message.to_s.truncate(500)
      )
    end

    def matching_review(agent_run)
      return unless agent_run.source_pull_request_number.present?

      reviews = agent_run.project.client&.pull_request_reviews(
        agent_run.project.full_name,
        agent_run.source_pull_request_number
      )
      Array(reviews).select { |review| matching_review?(agent_run, review) }
        .max_by { |review| review[:submitted_at] }
    end

    def matching_review?(agent_run, review)
      submitted_at = review[:submitted_at]
      return false unless submitted_at
      return false unless submitted_during_run?(agent_run, submitted_at)
      return false if review[:state].to_s.casecmp("PENDING").zero?

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
  end
end
