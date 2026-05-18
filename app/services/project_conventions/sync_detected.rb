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
        record = project.project_convention_detections.find_or_initialize_by(key: detection.fetch(:key))
        record.update!(
          detector_key: detection.fetch(:detector_key),
          confidence: detection.fetch(:confidence),
          value: detection.fetch(:value),
          evidence: detection.fetch(:evidence),
          detected_at: Time.current,
          project_version: project_version
        )
      end
    end

    def remove_stale_detections
      active_keys = detections.map { |detection| detection.fetch(:key) }
      project.project_convention_detections.where.not(key: active_keys).delete_all
    end
  end
end
