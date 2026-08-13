# frozen_string_literal: true

module LlmOutputMetrics
  # Collects quality feedback for LLM-generated issue titles.
  #
  # Signals:
  #   - title_edited (0.0 if edited, 1.0 if kept as-is) — inverse signal
  #   - issue_reaction (0.0-1.0) — positive/negative reaction ratio
  #
  # @example
  #   LlmOutputMetrics::CollectIssueTitleFeedback.call(
  #     project: project,
  #     issue_number: 123,
  #     current_title: "Updated title",
  #     original_title: "Generated title"
  #   )
  class CollectIssueTitleFeedback
    POSITIVE_REACTIONS = %w[+1 heart hooray rocket].freeze
    NEGATIVE_REACTIONS = %w[-1 confused].freeze

    def self.call(...)
      new(...).call
    end

    def initialize(project:, issue_number:, current_title: nil, original_title: nil, reactions: nil)
      @project = project
      @issue_number = issue_number
      @current_title = current_title
      @original_title = original_title
      @reactions = reactions
    end

    def call
      metric = find_metric
      return nil unless metric

      scores = {}
      feedback_metadata = {}

      collect_edit_signal(scores, feedback_metadata)
      collect_reaction_signal(scores, feedback_metadata)

      return metric if scores.empty?

      update_metric(metric, scores, feedback_metadata)
    end

    private

    attr_reader :project, :issue_number, :current_title, :original_title, :reactions

    def find_metric
      LlmOutputMetric.find_by(
        project: project,
        output_type: "issue_title",
        source_type: "Issue",
        source_id: issue_number
      )
    end

    def collect_edit_signal(scores, feedback_metadata)
      return if current_title.nil? || original_title.nil?

      edited = current_title.strip != original_title.strip
      scores["title_edited"] = edited ? 0.0 : 1.0
      feedback_metadata["title_edited"] = edited
    end

    def collect_reaction_signal(scores, feedback_metadata)
      return if reactions.nil? || reactions.empty?

      positive = reactions.count { |r| POSITIVE_REACTIONS.include?(r[:content]) }
      negative = reactions.count { |r| NEGATIVE_REACTIONS.include?(r[:content]) }
      total = positive + negative
      return if total.zero?

      scores["issue_reaction"] = (positive.to_f / total).round(4)
      feedback_metadata["reaction_counts"] = tally_reactions(reactions)
    end

    def tally_reactions(reaction_list)
      reaction_list.each_with_object(Hash.new(0)) do |r, counts|
        counts[r[:content]] += 1
      end
    end

    def update_metric(metric, scores, feedback_metadata)
      metric.scores = metric.scores.merge(scores)
      metric.metadata = metric.metadata.merge(
        feedback_metadata.merge("feedback_collected_at" => Time.current.iso8601)
      )
      metric.composite_score = metric.calculate_composite_score
      metric.save!
      metric
    end
  end
end
