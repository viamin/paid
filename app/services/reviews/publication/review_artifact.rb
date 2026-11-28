# frozen_string_literal: true

module Reviews
  module Publication
    # Structurally verifies a review payload and the bounded provider evidence
    # returned for it. This deliberately does not decide whether prose is a
    # finding; it only keeps a non-clean, malformed artifact from becoming a
    # delivered review.
    #
    # @spec REVIEW-PR-010
    class ReviewArtifact
      Result = Data.define(:status, :diagnostics)

      CLEAN_MARKER = Github::ReviewMarker::CLEAN_REVIEW_MARKER
      REVIEW_MARKER = Github::ReviewMarker::PAID_REVIEW_MARKER
      REVIEW_HEADER = Github::ReviewMarker::REVIEW_HEADER

      def self.submission(body: nil, comments: nil)
        new(body:, comments:).submission
      end

      def self.provider_result(submission:, review:, comments:, current_head_sha:)
        new(body: nil, comments: nil).provider_result(submission:, review:, comments:, current_head_sha:)
      end

      def initialize(body:, comments:)
        @body = body.to_s
        @comments = Array(comments)
      end

      def submission
        return result(:incomplete) if comment_bodies.any?(&:blank?)
        return result(:contentful_findings) if @comments.any?
        return result(:clean) if explicit_clean?(@body)
        return result(:summary) if review_text.present?

        result(:incomplete)
      end

      def provider_result(submission:, review:, comments:, current_head_sha:)
        return unavailable_result(submission) if provider_evidence_unavailable?(submission, review, comments, current_head_sha)

        @review = review
        @provider_comments = comments_for_review(comments, review_id)
        @current_head_sha = current_head_sha
        return provider_result_for_findings(submission) if submission.status == :contentful_findings
        return provider_result_for_clean(submission) if submission.status == :clean
        return provider_result_for_summary(submission) if submission.status == :summary

        result(:incomplete, submission.diagnostics)
      end

      private

      def provider_result_for_findings(submission)
        return result(:incomplete, submission.diagnostics) unless head_matches_review?
        return result(:incomplete, submission.diagnostics) unless @provider_comments.size == submission.diagnostics[:submitted_comment_count]
        return result(:incomplete, submission.diagnostics) if provider_comment_bodies.any?(&:blank?)

        result(:contentful_findings, submission.diagnostics)
      end

      def provider_result_for_clean(submission)
        return result(:incomplete, submission.diagnostics) unless explicit_clean?(review_body)

        result(:clean, submission.diagnostics)
      end

      def provider_result_for_summary(submission)
        return result(:incomplete, submission.diagnostics) unless review_text(review_body).present?

        result(:summary, submission.diagnostics)
      end

      def provider_evidence_unavailable?(submission, review, comments, current_head_sha)
        submission.status == :contentful_findings && (review.blank? || comments.nil? || current_head_sha.blank?)
      end

      def unavailable_result(submission)
        result(:provider_evidence_unavailable, submission.diagnostics)
      end

      def result(status, diagnostics = {})
        Result.new(status:, diagnostics: diagnostics.merge(shape_diagnostics(status)))
      end

      def shape_diagnostics(status)
        diagnostics = {
          publication_status: status.to_s,
          review_id: review_id,
          review_commit_id: review_value("commit_id"),
          current_head_sha: @current_head_sha,
          head_matches_review: head_matches_review?,
          provider_comment_count: @provider_comments&.size,
          provider_comment_ids: @provider_comments&.map { |comment| value(comment, "id") },
          provider_body_lengths: provider_comment_bodies&.map(&:length)
        }.compact
        return diagnostics if @body.nil? && @comments.empty?

        diagnostics.merge(
          submitted_comment_count: @comments.size,
          submitted_body_lengths: comment_bodies.map(&:length)
        )
      end

      def comment_bodies
        @comment_bodies ||= @comments.map { |comment| value(comment, "body").to_s }
      end

      def provider_comment_bodies
        return unless @provider_comments

        @provider_comment_bodies ||= @provider_comments.map { |comment| value(comment, "body").to_s }
      end

      def comments_for_review(comments, id)
        Array(comments).select { |comment| value(comment, "pull_request_review_id").to_s == id.to_s }
      end

      def review_id
        review_value("id")
      end

      def review_value(key)
        value(@review, key)
      end

      def value(record, key)
        return unless record.respond_to?(:[])

        record[key] || record[key.to_sym]
      end

      def head_matches_review?
        @current_head_sha.present? && review_value("commit_id").to_s == @current_head_sha.to_s
      end

      def review_body
        review_value("body").to_s
      end

      def review_text(body = @body)
        body.to_s
          .delete_prefix(REVIEW_MARKER)
          .delete_prefix("\n#{REVIEW_HEADER}")
          .strip
      end

      def explicit_clean?(body)
        review_text(body).start_with?("Generated no new comments.") && body.to_s.include?(CLEAN_MARKER)
      end
    end
  end
end
