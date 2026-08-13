# frozen_string_literal: true

module QualityMetrics
  # Collects human feedback for enhance_issue comments.
  # Reactions are scoped to the marked enhancement comment, and author_replied
  # records whether the original issue author commented after that enhancement.
  class CollectEnhanceIssueFeedback
    POSITIVE_REACTIONS = CollectReactionFeedback::POSITIVE_REACTIONS
    NEGATIVE_REACTIONS = CollectReactionFeedback::NEGATIVE_REACTIONS

    attr_reader :agent_run

    def initialize(agent_run:)
      @agent_run = agent_run
    end

    def self.call(...)
      new(...).call
    end

    def call
      return nil unless agent_run.enhance_issue_goal?
      return nil unless agent_run.issue && github_client

      comments = fetch_comments
      enhancement = enhancement_comment(comments)
      return nil unless enhancement

      reactions = fetch_reactions(comment_id(enhancement))
      record_feedback(
        reaction_score(reactions),
        reactions,
        author_replied?(comments, enhancement)
      )
    end

    private

    def github_client
      return unless agent_run.project.github_credential_present?

      agent_run.project.client
    end

    def fetch_comments
      github_client.issue_comments(agent_run.project.full_name, agent_run.issue.github_number)
    rescue GithubClient::Error => e
      Rails.logger.warn(
        message: "quality_metrics.enhance_issue_comment_fetch_failed",
        agent_run_id: agent_run.id,
        error: e.message
      )
      []
    end

    def fetch_reactions(comment_id)
      return [] unless comment_id

      github_client.issue_comment_reactions(agent_run.project.full_name, comment_id)
    rescue GithubClient::Error => e
      Rails.logger.warn(
        message: "quality_metrics.enhance_issue_reaction_fetch_failed",
        agent_run_id: agent_run.id,
        comment_id: comment_id,
        error: e.message
      )
      []
    end

    def enhancement_comment(comments)
      comments.find { |comment| value(comment, :body).to_s.include?(Activities::EnhanceIssueActivity::COMMENT_MARKER) }
    end

    def author_replied?(comments, enhancement)
      author = agent_run.issue.github_creator_login
      enhanced_at = value(enhancement, :created_at)
      return false unless author.present? && enhanced_at

      comments.any? do |comment|
        next false if comment_id(comment) == comment_id(enhancement)

        commented_at = value(comment, :created_at)
        next false unless commented_at && commented_at.to_time > enhanced_at.to_time

        user_login(comment) == author
      end
    end

    def reaction_score(reactions)
      positive = reactions.count { |reaction| POSITIVE_REACTIONS.include?(reaction[:content]) }
      negative = reactions.count { |reaction| NEGATIVE_REACTIONS.include?(reaction[:content]) }
      total = positive + negative

      return nil if total.zero?

      (positive.to_f / total).round(4)
    end

    def record_feedback(reaction_score, reactions, author_replied)
      ActiveRecord::Base.transaction do
        metric = agent_run.quality_metrics.where(metric_type: "human").lock.first
        metric ||= agent_run.quality_metrics.build(metric_type: "human")

        metric.prompt_version = agent_run.prompt_version
        metric.feedback_source ||= "enhance_issue_feedback"
        metric.scores = updated_scores(metric.scores || {}, reaction_score, author_replied)
        metric.metadata = updated_metadata(metric.metadata || {}, reactions)
        metric.composite_score = metric.calculate_composite_score
        metric.save!
        metric
      end
    rescue ActiveRecord::RecordNotUnique
      retry
    end

    def updated_scores(existing_scores, reaction_score, author_replied)
      scores = existing_scores.merge("author_replied" => author_replied ? 1.0 : 0.0)
      scores["reaction_score"] = reaction_score unless reaction_score.nil?
      scores
    end

    def updated_metadata(existing_metadata, reactions)
      existing_sources = Array(existing_metadata["feedback_sources"])
      existing_metadata.merge(
        "feedback_sources" => (existing_sources + [ "enhance_issue_feedback" ]).uniq,
        "reaction_counts" => tally_reactions(reactions),
        "collected_at" => Time.current.iso8601
      )
    end

    def tally_reactions(reactions)
      reactions.each_with_object(Hash.new(0)) do |reaction, counts|
        counts[reaction[:content]] += 1
      end
    end

    def comment_id(comment)
      value(comment, :id)
    end

    def user_login(comment)
      user = value(comment, :user)
      value(user, :login)
    end

    def value(object, key)
      return object[key] || object[key.to_s] if object.respond_to?(:[])
      return object.public_send(key) if object.respond_to?(key)

      nil
    end
  end
end
