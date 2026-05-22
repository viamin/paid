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
        project_version: effective_project_version,
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
      resolved_entry(entry_key, detected:, override:, default:)
    end

    def resolved_entry(entry_key, detected:, override:, default:)
      if override&.apply?
        result(apply_branch(entry_key, detected, override))
      elsif override&.warn?
        result(warn_branch(entry_key, detected, override))
      elsif override&.ignore?
        result(ignore_branch(entry_key, detected, override, default))
      elsif detected[:record]
        result(detection_branch(entry_key, detected))
      else
        result(default_branch(entry_key, default))
      end
    end

    def result(attrs)
      attrs.merge(drift: attrs[:conflict].present?)
    end

    def apply_branch(entry_key, detected, override)
      common_override_attrs(entry_key, detected, override).merge(
        value: merge_values(detected.fetch(:value), override.value),
        source: "override",
        confidence: detected.fetch(:confidence, 0.0),
        enabled: true,
        conflict: conflict_for(key: entry_key, category: override.category, status: "override_applied",
                               detected:, override:)
      )
    end

    def warn_branch(entry_key, detected, override)
      common_override_attrs(entry_key, detected, override).merge(
        value: detected.fetch(:value),
        source: "warning",
        confidence: detected.fetch(:confidence, 0.0),
        enabled: true,
        conflict: conflict_for(key: entry_key, category: override.category, status: "override_warning",
                               detected:, override:)
      )
    end

    def ignore_branch(entry_key, detected, override, default)
      common_override_attrs(entry_key, detected, override).merge(
        value: default,
        source: "override",
        confidence: 0.0,
        enabled: false,
        conflict: conflict_for(key: entry_key, category: override.category,
                               status: "override_ignored_detection", detected:, override:)
      )
    end

    def detection_branch(entry_key, detected)
      {
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
      }
    end

    def default_branch(entry_key, default)
      {
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
      }
    end

    def common_override_attrs(entry_key, detected, override)
      {
        key: entry_key,
        category: override.category,
        policy_mode: override.mode,
        override: override,
        detection: detected[:record],
        detected_value: detected_value_for(detected),
        evidence: detected[:evidence],
        configured_value: override.value.deep_stringify_keys,
        detected_at: detected[:detected_at],
        detected_commit_sha: detected[:commit_sha]
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
        commit_sha: primary&.read_attribute(:detected_commit_sha),
        record: primary,
        records: detections,
        value: base_value
      }
    end

    def detection_records(entry_key)
      return all_detections.select { |record| record.key == entry_key } if profile_records_loaded?

      scope = detection_scope.where(key: entry_key)
      scope.order(confidence: :desc, detected_at: :desc, id: :desc).to_a
    end

    def override_record(entry_key)
      return all_overrides.find { |record| record.key == entry_key } if profile_records_loaded?

      project.project_convention_overrides.find_by(key: entry_key)
    end

    def preload_profile_records
      return if profile_records_loaded?

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

    def effective_project_version
      @effective_project_version ||= project_version || project.project_versions.by_recency.first
    end

    def detection_scope
      scope = project.project_convention_detections
        .joins(:project_version)
        .select(
          "#{ProjectConventionDetection.table_name}.*",
          "#{ProjectVersion.table_name}.commit_sha AS detected_commit_sha"
        )
      effective_project_version ? scope.where(project_version: effective_project_version) : scope
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
      return if detected[:record].blank?

      configured_value = override.value.deep_stringify_keys
      detected_value = detected.fetch(:value)
      return if subset_match?(configured_value, detected_value)

      {
        key: key,
        category: category,
        status: status,
        detected_value: detected_value,
        configured_value: configured_value,
        evidence: detected.fetch(:evidence),
        message: "#{key} #{status.tr('_', ' ')}"
      }
    end

    def detected_value_for(detected)
      detected[:record] ? detected.fetch(:value) : nil
    end

    def subset_match?(expected, actual)
      case expected
      when Hash
        return false unless actual.is_a?(Hash)

        expected.all? { |key, value| subset_match?(value, actual[key]) }
      when Array
        expected == actual
      else
        expected == actual
      end
    end
  end
end
