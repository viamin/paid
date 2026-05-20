# frozen_string_literal: true

module ProjectConventions
  class SyncDetected
    def self.call(...)
      new(...).call
    end

    def initialize(project:, project_version:, detections:)
      @project = project
      @project_version = project_version
      @detections = detections
    end

    def call
      ActiveRecord::Base.transaction do
        upsert_detections
        remove_stale_detections
      end
    end

    private

    attr_reader :project, :project_version, :detections

    def upsert_detections
      detections.each do |detection|
        record = project.project_convention_detections.find_or_initialize_by(
          key: detection.fetch(:key),
          detector_key: detection.fetch(:detector_key),
          project_version: project_version
        )
        record.update!(
          confidence: detection.fetch(:confidence),
          value: detection.fetch(:value),
          evidence: detection.fetch(:evidence),
          detected_at: Time.current,
          project_version: project_version
        )
      end
    end

    def remove_stale_detections
      project.project_convention_detections.where(project_version: project_version).find_each do |record|
        next if detections.any? { |detection| detection_identity(detection) == detection_identity(record) }

        record.destroy!
      end
    end

    def detection_identity(detection)
      if detection.respond_to?(:fetch)
        return [ detection.fetch(:key), detection.fetch(:detector_key) ]
      end

      [ detection.key, detection.detector_key ]
    end
  end
end
