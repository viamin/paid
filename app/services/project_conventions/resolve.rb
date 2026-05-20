# frozen_string_literal: true

module ProjectConventions
  class Resolve
    DEFAULTS = {
      "commit_style" => {
        "type" => "conventional_commits",
        "required" => false,
        "default_type" => "feat"
      }.freeze,
      "pr_title_style" => {
        "type" => "conventional_commits",
        "required" => false
      }.freeze,
      "issue_dependency_format" => {
        "depends_on_prefix" => "Depends on",
        "blocked_by_prefix" => "Blocked by",
        "heading" => "## Dependencies"
      }.freeze
    }.freeze

    attr_reader :project, :key, :project_version

    def initialize(project:, key:, project_version: nil)
      @project = project
      @key = key.to_s
      @project_version = project_version
    end

    def self.call(...)
      new(...).call
    end

    def self.value_for(project:, key:, project_version: nil)
      call(project:, key:, project_version:).fetch(:value)
    end

    def call
      resolved_detection = detection_value
      override = project.project_convention_overrides.find_by(key: key)

      if override
        detection_base = resolved_detection.present? ? merge_values(default_value, resolved_detection) : default_value
        value = override.enabled ? merge_values(detection_base, override.value) : default_value
        return result(
          value: value,
          source: "override",
          enabled: override.enabled,
          confidence: override.enabled ? 1.0 : 0.0,
          override: override,
          detection: detection_record,
          drift: override.enabled && resolved_detection.present? && value != merge_values(default_value, resolved_detection)
        )
      end

      if resolved_detection.present?
        return result(
          value: merge_values(default_value, resolved_detection),
          source: "detection",
          enabled: true,
          confidence: detection_record&.confidence.to_f,
          override: nil,
          detection: detection_record,
          drift: false
        )
      end

      result(
        value: default_value,
        source: default_value.present? ? "default" : "unset",
        enabled: default_value.present?,
        confidence: 0.0,
        override: nil,
        detection: nil,
        drift: false
      )
    end

    private

    def result(value:, source:, enabled:, confidence:, override:, detection:, drift:)
      {
        key: key,
        value: value,
        source: source,
        enabled: enabled,
        confidence: confidence,
        override: override,
        detection: detection,
        drift: drift
      }
    end

    def detection_record
      @detection_record ||= begin
        scope = project.project_convention_detections.where(key: key)
        scope = scope.where(project_version: project_version) if project_version
        scope.order(detected_at: :desc, updated_at: :desc, id: :desc).first
      end
    end

    def detection_value
      detection_record&.value
    end

    def default_value
      DEFAULTS.fetch(key, {}).deep_dup
    end

    def merge_values(base, override)
      base = (base || {}).deep_dup
      override = (override || {}).deep_stringify_keys
      return override if base.blank?

      base.deep_merge(override)
    end
  end
end
