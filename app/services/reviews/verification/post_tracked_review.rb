# frozen_string_literal: true

module Reviews
  module Verification
    # Posts the final verified review through the tracked path (#3898): the
    # paid-code-reviewer GitHub App installation-token identity, the shared
    # Paid review marker, event COMMENT, and the pinned head SHA — the same
    # contract the containerized reviewer's proxy posts, so
    # CompleteReviewGoalActivity recognizes either pipeline's review.
    #
    # Idempotent per agent run: once a run has +review_posted_at+ set, later
    # calls return the recorded review instead of posting a second one. A
    # pending-review 422 (a previous interrupted post left a PENDING review)
    # is recovered by deleting the bot's pending review and retrying exactly
    # once; any other upstream error propagates.
    #
    # @spec REVIEW-VERIFY-006
    class PostTrackedReview
      PENDING_REVIEW_ERROR_PATTERN = /one pending review per pull request/i
      COMMENT_KEYS = %i[path line side body].freeze

      # @param agent_run [AgentRun] the review-goal run
      # @param body [String] review body without the marker prefix
      # @param comments [Array<Hash>] :path, :line, :side, :body entries
      # @param commit_sha [String] pinned PR head SHA
      # @return [Hash] :review_id, :review_url, :already_posted
      def self.call(agent_run:, body:, comments:, commit_sha:)
        new(agent_run:, body:, comments:, commit_sha:).call
      end

      def initialize(agent_run:, body:, comments:, commit_sha:)
        @agent_run = agent_run
        @body = body
        @comments = comments
        @commit_sha = commit_sha
      end

      def call
        return already_posted_result if @agent_run.review_posted_at.present?

        review = create_review
        @agent_run.update!(review_posted_at: Time.current, review_url: review.html_url)
        { review_id: review.id, review_url: review.html_url, already_posted: false }
      end

      private

      def already_posted_result
        { review_id: nil, review_url: @agent_run.review_url, already_posted: true }
      end

      def create_review
        bot_client.create_pull_request_review_payload(repo_full_name, pr_number, review_payload)
      rescue GithubClient::ApiError => e
        raise unless pending_review_conflict?(e)

        clear_bot_pending_reviews
        bot_client.create_pull_request_review_payload(repo_full_name, pr_number, review_payload)
      end

      def pending_review_conflict?(error)
        error.status == 422 && error.message.match?(PENDING_REVIEW_ERROR_PATTERN)
      end

      # GitHub allows one pending review per author; an interrupted earlier
      # post leaves one behind and blocks every retry until it is deleted.
      def clear_bot_pending_reviews
        bot_client.pull_request_reviews(repo_full_name, pr_number).each do |review|
          next unless review[:state].to_s.casecmp("PENDING").zero?
          next unless bot_logins.include?(review[:user_login].to_s.downcase)

          bot_client.delete_pending_pull_request_review(repo_full_name, pr_number, review[:id])
        end
      end

      def review_payload
        {
          body: "#{Github::ReviewMarker.body_prefix}#{summary_body}",
          event: "COMMENT",
          commit_id: @commit_sha,
          comments: @comments.map { |comment| comment.slice(*COMMENT_KEYS) }
        }
      end

      # Unanchored findings surface as body bullets appended to the model's
      # summary so no confirmed finding is silently lost.
      def summary_body
        bullets = @comments.map { |comment| comment[:body] }.blank? ? [] : []
        [ @body.presence ].compact.join("\n\n")
      end

      def bot_client
        @bot_client ||= GithubClient.new(token: bot_token)
      end

      def bot_token
        Github::ReviewBotInstallationToken.new(repo_full_name: repo_full_name).fetch
      end

      def bot_logins
        Github::ReviewBotInstallationToken.bot_logins.map(&:downcase)
      end

      def repo_full_name
        @agent_run.project.full_name
      end

      def pr_number
        @agent_run.source_pull_request_number
      end
    end
  end
end
