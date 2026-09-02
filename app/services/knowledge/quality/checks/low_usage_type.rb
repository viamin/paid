# frozen_string_literal: true

require_relative "base"

module Knowledge
  module Quality
    # Flags artifact types that exist on the project but have received no
    # retrieval traffic in the recent window. The threshold defaults to 0
    # usages in the last 30 days, which is intentionally noisy so operators
    # can tune it (or filter the report) once the signal stabilizes.
    class Checks::LowUsageType < Checks::Base
      code "low_usage_type"
      severity "info"

      def initialize(project:, since: 30.days.ago)
        super(project: project)
        @since = since
      end

      def collect_findings(collector)
        candidate_types = active_artifact_types - used_artifact_types
        candidate_types.sort.each do |type|
          add_finding(
            collector,
            target_type: "ArtifactType",
            target_id: type,
            detail: "no retrieval usage in the last #{(Time.current - @since).round / 1.day} days"
          )
        end
      end

      private

      def used_artifact_types
        KnowledgeUsageStat
          .for_project(project)
          .since(@since)
          .distinct
          .pluck(:artifact_type)
      end

      def active_artifact_types
        KnowledgeArtifact
          .active
          .for_project(project)
          .distinct
          .pluck(:artifact_type)
      end
    end
  end
end
