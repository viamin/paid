# frozen_string_literal: true

module Activities
  # Persists LLM analysis results as KnowledgeRecommendation records.
  #
  # Creates new recommendations with status "pending", skips duplicates
  # (same recommendation_type + collector_type + project with status "pending"),
  # and closes stale recommendations no longer flagged by the LLM.
  class RecordKnowledgeRecommendationsActivity < BaseActivity
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
      stale = project.knowledge_recommendations.pending.select do |rec|
        !flagged_keys.include?([ rec.recommendation_type, rec.collector_type ])
      end

      stale.each { |rec| rec.dismiss!(reason: "no_longer_flagged") }
      stale.size
    end
  end
end
