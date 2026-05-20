# frozen_string_literal: true

module Knowledge
  module Collectors
    class ProjectConventionsCollector < BaseCollector
      def collect
        detections = ProjectConventions::Detector.call(repo_path: host_repo_path)
        ProjectConventions::SyncDetected.call(project:, project_version:, detections:)
        ProjectConventions::SyncRecommendations.call(project:, detections:)

        detections.map do |detection|
          build_artifact(detection)
        end
      end

      def collector_type
        "project_conventions"
      end

      private

      def build_artifact(detection)
        evidence_paths = Array(detection.dig(:evidence, "paths"))
        {
          artifact_type: "project_convention",
          scope_path: evidence_paths.first,
          identifier: detection.fetch(:key),
          content: JSON.pretty_generate(detection.fetch(:value)),
          metadata: {
            confidence: detection.fetch(:confidence),
            detector_key: detection.fetch(:detector_key),
            evidence: detection.fetch(:evidence)
          },
          chunks: [
            {
              chunk_type: "summary",
              content: "#{detection.fetch(:key)} => #{detection.fetch(:value).to_json}",
              scope_tags: [ "project_convention" ],
              sequence: 0
            }
          ]
        }
      end
    end
  end
end
