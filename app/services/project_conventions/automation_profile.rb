# frozen_string_literal: true

module ProjectConventions
  class AutomationProfile
    RELEVANT_KEYS = %w[commit_style pr_title_style issue_dependency_format release_automation].freeze

    def self.for(project:)
      new(project: project)
    end

    attr_reader :project

    def initialize(project:)
      @project = project
    end

    def convention(key)
      conventions.fetch(key.to_s) { default_entry(key) }
    end

    def value(key)
      convention(key).fetch(:value)
    end

    def required?(key)
      entry = convention(key)
      entry[:enabled] && entry.fetch(:value, {}).fetch("required", false) == true
    end

    def significant_for_release?(key = "pr_title_style")
      convention(key).fetch(:value, {}).fetch("significant_for_release", false) == true
    end

    def allowed_types(key)
      Array(value(key)["allowed_types"]).filter_map(&:presence)
    end

    private

    def conventions
      @conventions ||= resolved_profile.fetch(:conventions)
    end

    def resolved_profile
      return { conventions: RELEVANT_KEYS.index_with { |key| default_entry(key) } } unless resolvable_project?

      @resolved_profile ||= Resolve.profile(project:)
    rescue ActiveRecord::ActiveRecordError => e
      Rails.logger.warn(
        message: "project_conventions.automation_profile_lookup_failed",
        project_id: project&.id,
        error: e.message
      )

      {
        conventions: RELEVANT_KEYS.index_with { |key| default_entry(key) }
      }
    end

    def resolvable_project?
      project.respond_to?(:project_convention_detections) &&
        project.respond_to?(:project_convention_overrides)
    end

    def default_entry(key)
      value = Catalog.default_for(key)

      {
        key: key.to_s,
        category: Catalog.category_for(key),
        value: value,
        source: value.present? ? "default" : "unset",
        enabled: value.present?
      }
    end
  end
end
