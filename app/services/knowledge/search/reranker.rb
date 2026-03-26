# frozen_string_literal: true

module Knowledge
  class Search
    class Reranker
      VERSION_BOOST = 0.15
      ACTIVE_BOOST = 0.10
      LINK_BOOST = 0.05
      MAX_LINK_BOOST_COUNT = 3
      AGE_PENALTY_PER_DAY = 0.01
      MAX_AGE_PENALTY_DAYS = 10

      attr_reader :results, :target_sha

      def initialize(results:, target_sha: nil)
        @results = results
        @target_sha = target_sha
      end

      def self.call(...)
        new(...).call
      end

      def call
        results.map { |result| score_result(result) }
          .sort_by { |r| -r[:score] }
      end

      private

      def score_result(result)
        base = result[:score] || 0.0

        base += VERSION_BOOST if version_match?(result)
        base += ACTIVE_BOOST if result[:status] == "active"
        base += link_boost(result)
        base -= age_penalty(result)

        result.merge(score: base.round(4))
      end

      def version_match?(result)
        return false if target_sha.blank?

        result.dig(:project_version, :commit_sha) == target_sha
      end

      def link_boost(result)
        count = [ result[:link_count].to_i, MAX_LINK_BOOST_COUNT ].min
        LINK_BOOST * count
      end

      def age_penalty(result)
        return 0.0 unless result[:created_at]

        age_days = (Time.current - result[:created_at]) / 1.day
        AGE_PENALTY_PER_DAY * [ age_days, MAX_AGE_PENALTY_DAYS ].min
      end
    end
  end
end
