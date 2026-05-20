# frozen_string_literal: true

module ProjectConventions
  class Resolve
    DEFAULTS = Catalog::DEFINITIONS.transform_values { |definition| definition.fetch(:default).deep_dup }.freeze

    attr_reader :project, :key, :project_version

    def initialize(project:, key: nil, project_version: nil)
      @project = project
      @key = key&.to_s
      @project_version = project_version
    end

    def self.call(...)
      new(...).call
    end

    def self.value_for(project:, key:, project_version: nil)
      call(project:, key:, project_version:).fetch(:value)
    end

    def self.profile(project:, project_version: nil)
      call(project:, project_version:)
    end

    def call
      return profile if key.blank?

      convention_entry(key)
    end

    private

    def profile
      preload_profile_records
      conventions = profile_keys.index_with { |profile_key| convention_entry(profile_key) }

      {
        project: project,
        project_version: project_version,
        conventions: conventions,
        conflicts: conventions.values.filter_map { |entry| entry[:conflict] }
      }
    end

    def profile_keys
      (
        Catalog.known_keys +
        all_detections.map(&:key) +
        all_overrides.map(&:key)
      ).uniq.sort
    end

    def convention_entry(entry_key)
      detected = detected_state(entry_key)
      override = override_record(entry_key)
      default = default_value(entry_key)

      if override&.apply?
        value = merge_values(detected.fetch(:value), override.value)
        return result(
          key: entry_key,
          category: override.category,
          value: value,
          source: "override",
          enabled: true,
          confidence: detected.fetch(:confidence, 0.0),
          policy_mode: override.mode,
          override: override,
          detection: detected[:record],
          detected_value: detected[:value],
          evidence: detected[:evidence],
          configured_value: override.value.deep_stringify_keys,
          detected_at: detected[:detected_at],
          detected_commit_sha: detected[:commit_sha],
          conflict: conflict_for(
            key: entry_key,
            category: override.category,
            status: "override_applied",
            detected: detected,
            override: override
          )
        )
      end

      if override&.warn?
        return result(
          key: entry_key,
          category: override.category,
          value: detected.fetch(:value),
          source: "warning",
          enabled: true,
          confidence: detected.fetch(:confidence, 0.0),
          policy_mode: override.mode,
          override: override,
          detection: detected[:record],
          detected_value: detected[:value],
          evidence: detected[:evidence],
          configured_value: override.value.deep_stringify_keys,
          detected_at: detected[:detected_at],
          detected_commit_sha: detected[:commit_sha],
          conflict: conflict_for(
            key: entry_key,
            category: override.category,
            status: "override_warning",
            detected: detected,
            override: override
          )
        )
      end

      if override&.ignore?
        return result(
          key: entry_key,
          category: override.category,
          value: default,
          source: "override",
          enabled: false,
          confidence: 0.0,
          policy_mode: override.mode,
          override: override,
          detection: detected[:record],
          detected_value: detected[:value],
          evidence: detected[:evidence],
          configured_value: override.value.deep_stringify_keys,
          detected_at: detected[:detected_at],
          detected_commit_sha: detected[:commit_sha],
          conflict: conflict_for(
            key: entry_key,
            category: override.category,
            status: "override_ignored_detection",
            detected: detected,
            override: override
          )
        )
      end

      if detected[:record]
        return result(
          key: entry_key,
          category: detected[:category],
          value: detected[:value],
          source: "detection",
          enabled: true,
          confidence: detected[:confidence],
          policy_mode: nil,
          override: nil,
          detection: detected[:record],
          detected_value: detected[:value],
          evidence: detected[:evidence],
          configured_value: nil,
          detected_at: detected[:detected_at],
          detected_commit_sha: detected[:commit_sha],
          conflict: nil
        )
      end

      result(
        key: entry_key,
        category: Catalog.category_for(entry_key),
        value: default,
        source: default.present? ? "default" : "unset",
        enabled: default.present?,
        confidence: 0.0,
        policy_mode: nil,
        override: nil,
        detection: nil,
        detected_value: default,
        evidence: { "paths" => [], "signals" => [] },
        configured_value: nil,
        detected_at: nil,
        detected_commit_sha: nil,
        conflict: nil
      )
    end

    def result(key:, category:, value:, source:, enabled:, confidence:, policy_mode:, override:, detection:,
      detected_value:, evidence:, configured_value:, detected_at:, detected_commit_sha:, conflict:)
      {
        key: key,
        category: category,
        value: value,
        source: source,
        enabled: enabled,
        confidence: confidence,
        policy_mode: policy_mode,
        override: override,
        detection: detection,
        detected_value: detected_value,
        evidence: evidence,
        configured_value: configured_value,
        detected_at: detected_at,
        detected_commit_sha: detected_commit_sha,
        conflict: conflict,
        drift: conflict.present?
      }
    end

    def detected_state(entry_key)
      detections = detection_records(entry_key)
      primary = detections.max_by { |record| [ record.confidence.to_f, record.detected_at, record.id ] }
      base_value = merge_values(default_value(entry_key), primary&.value)

      {
        category: primary&.category || Catalog.category_for(entry_key),
        confidence: primary&.confidence.to_f,
        evidence: merge_evidence(detections),
        detected_at: primary&.detected_at,
        commit_sha: primary&.project_version_commit_sha,
        record: primary,
        records: detections,
        value: base_value
      }
    end

    def detection_records(entry_key)
      return all_detections.select { |record| record.key == entry_key } if profile_records_loaded?

      scope = project.project_convention_detections.preload(:project_version).where(key: entry_key)
      scope = scope.where(project_version: project_version) if project_version
      scope.order(confidence: :desc, detected_at: :desc, id: :desc).to_a
    end

    def override_record(entry_key)
      return all_overrides.find { |record| record.key == entry_key } if profile_records_loaded?

      project.project_convention_overrides.find_by(key: entry_key)
    end

    def preload_profile_records
      return if profile_records_loaded?

      detection_scope = project.project_convention_detections.preload(:project_version)
      detection_scope = detection_scope.where(project_version: project_version) if project_version

      @all_detections = detection_scope.order(confidence: :desc, detected_at: :desc, id: :desc).to_a
      @all_overrides = project.project_convention_overrides.to_a
    end

    def all_detections
      @all_detections || []
    end

    def all_overrides
      @all_overrides || []
    end

    def profile_records_loaded?
      defined?(@all_detections) && defined?(@all_overrides)
    end

    def default_value(entry_key)
      Catalog.default_for(entry_key)
    end

    def merge_values(base, override)
      base = (base || {}).deep_dup
      override = (override || {}).deep_stringify_keys
      return override if base.blank?

      base.deep_merge(override)
    end

    def merge_evidence(detections)
      {
        "paths" => detections.flat_map { |record| Array(record.evidence["paths"]) }.uniq,
        "signals" => detections.flat_map { |record| Array(record.evidence["signals"]) }.uniq
      }
    end

    def conflict_for(key:, category:, status:, detected:, override:)
      return if override.value.deep_stringify_keys == detected.fetch(:value)
      return if status == "override_ignored_detection" && detected[:record].blank?

      {
        key: key,
        category: category,
        status: status,
        detected_value: detected.fetch(:value),
        configured_value: override.value.deep_stringify_keys,
        evidence: detected.fetch(:evidence),
        message: "#{key} #{status.tr('_', ' ')}"
      }
    end
  end
end
