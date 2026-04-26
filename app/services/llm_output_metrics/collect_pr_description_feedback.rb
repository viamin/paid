# frozen_string_literal: true

module LlmOutputMetrics
  # Collects quality feedback for LLM-generated PR descriptions.
  #
  # Signals:
  #   - description_edited (0.0 if edited, 1.0 if kept as-is) — inverse signal
  #   - description_length_ratio (0.0-1.0) — penalizes extreme ratios
  #   - pr_reaction (0.0-1.0) — positive/negative reaction ratio
  #
  # @example
  #   LlmOutputMetrics::CollectPrDescriptionFeedback.call(
  #     project: project,
  #     pull_request_number: 42,
  #     current_description: "...",
  #     original_description: "...",
  #     diff_size: 500
  #   )
  class CollectPrDescriptionFeedback
    POSITIVE_REACTIONS = %w[+1 heart hooray rocket].freeze
    NEGATIVE_REACTIONS = %w[-1 confused].freeze

    # Ideal description-to-diff ratio range (characters / changed lines).
    # diff_size is in lines (GitHub additions + deletions), description
    # length is in characters, so the ratio has units of chars/line.
    # Typical values: 0.5 (terse) to 10+ (verbose). Below MIN or above
    # MAX degrades the length ratio score.
    MIN_LENGTH_RATIO = 0.5
    MAX_LENGTH_RATIO = 10.0

    def self.call(...)
      new(...).call
    end

    def initialize(project:, pull_request_number:, current_description: nil,
                   original_description: nil, diff_size: nil, reactions: nil)
      @project = project
      @pull_request_number = pull_request_number
      @current_description = current_description
      @original_description = original_description
      @diff_size = diff_size
      @reactions = reactions
    end

    def call
      metric = find_metric
      return nil unless metric

      scores = {}
      feedback_metadata = {}

      collect_edit_signal(scores, feedback_metadata)
      collect_length_ratio_signal(scores, feedback_metadata)
      collect_reaction_signal(scores, feedback_metadata)

      return metric if scores.empty?

      update_metric(metric, scores, feedback_metadata)
    end

    private

    attr_reader :project, :pull_request_number, :current_description,
      :original_description, :diff_size, :reactions

    def find_metric
      LlmOutputMetric.find_by(
        project: project,
        output_type: "pr_description",
        source_type: "PullRequest",
        source_id: pull_request_number
      )
    end

    def collect_edit_signal(scores, feedback_metadata)
      return if current_description.nil? || original_description.nil?

      edited = current_description.strip != original_description.strip
      scores["description_edited"] = edited ? 0.0 : 1.0
      feedback_metadata["description_edited"] = edited
    end

    def collect_length_ratio_signal(scores, feedback_metadata)
      return if current_description.blank? || diff_size.nil? || diff_size.zero?

      ratio = current_description.length.to_f / diff_size
      feedback_metadata["description_length_ratio_raw"] = ratio.round(4)

      scores["description_length_ratio"] = length_ratio_score(ratio)
    end

    def length_ratio_score(ratio)
      return 0.0 if ratio <= 0

      if ratio < MIN_LENGTH_RATIO
        (ratio / MIN_LENGTH_RATIO).round(4)
      elsif ratio > MAX_LENGTH_RATIO
        [ 1.0 - ((ratio - MAX_LENGTH_RATIO) / MAX_LENGTH_RATIO), 0.0 ].max.round(4)
      else
        1.0
      end
    end

    def collect_reaction_signal(scores, feedback_metadata)
      return if reactions.nil? || reactions.empty?

      positive = reactions.count { |r| POSITIVE_REACTIONS.include?(r[:content]) }
      negative = reactions.count { |r| NEGATIVE_REACTIONS.include?(r[:content]) }
      total = positive + negative
      return if total.zero?

      scores["pr_reaction"] = (positive.to_f / total).round(4)
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
