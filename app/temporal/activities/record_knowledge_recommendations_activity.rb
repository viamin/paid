# frozen_string_literal: true

module Activities
  # Persists LLM analysis results as KnowledgeRecommendation records.
  #
  # Creates new recommendations with status "pending", skips duplicates
  # (same recommendation_type + collector_type + project with status "pending"),
  # and closes stale recommendations no longer flagged by the LLM.
  #
  # Idempotent on Temporal retry (#2770): the pending-duplicate check means a
  # retry that replays identical recommendations reuses the rows a previous
  # attempt already created instead of duplicating them, and stale-dismissal
  # is a pure function of the flagged recommendation set.
  class RecordKnowledgeRecommendationsActivity < BaseActivity
    # @spec KNOWLEDGE-008
    activity_name "RecordKnowledgeRecommendations"

    def execute(input)
      project_id = input[:project_id]
      recommendations = input[:recommendations]

      project = Project.find(project_id)
      created_count = 0
      flagged_keys = Set.new

      Array(recommendations).each do |rec|
        rec_type = rec[:recommendation_type].to_s
        collector = rec[:collector_type].presence
        next unless valid_recommendation?(rec_type, collector)

        flagged_keys << [ rec_type, collector ]

        existing = project.knowledge_recommendations.pending
          .find_by(recommendation_type: rec_type, collector_type: collector)
        next if existing

        project.knowledge_recommendations.create!(
          recommendation_type: rec_type,
          collector_type: collector,
          priority: rec[:priority] || "medium",
          description: rec[:description] || "Identified by knowledge evolution analysis",
          evidence: (rec[:evidence] || {}).deep_stringify_keys,
          status: "pending"
        )
        created_count += 1
      end

      dismissed_count = dismiss_stale_recommendations(project, flagged_keys)

      logger.info(
        message: "knowledge_evolution.recommendations_recorded",
        project_id: project_id,
        created_count: created_count,
        dismissed_count: dismissed_count
      )

      {
        project_id: project_id,
        created_count: created_count,
        dismissed_count: dismissed_count
      }
    end

    private

    def valid_recommendation?(rec_type, collector_type)
      return false unless KnowledgeRecommendation::RECOMMENDATION_TYPES.include?(rec_type)

      # knowledge_gap recommendations may not be tied to a specific collector
      rec_type == "knowledge_gap" || collector_type.present?
    end

    def dismiss_stale_recommendations(project, flagged_keys)
      scope = project.knowledge_recommendations.pending

      if flagged_keys.any?
        table = KnowledgeRecommendation.arel_table
        exclude = flagged_keys.reduce(nil) do |combined, (rec_type, collector)|
          condition = if collector.nil?
            table[:recommendation_type].eq(rec_type).and(table[:collector_type].eq(nil))
          else
            table[:recommendation_type].eq(rec_type).and(table[:collector_type].eq(collector))
          end
          combined ? combined.or(condition) : condition
        end
        scope = scope.where.not(exclude)
      end

      count = scope.count
      scope.find_each { |rec| rec.dismiss!(reason: "no_longer_flagged") }
      count
    end
  end
end
