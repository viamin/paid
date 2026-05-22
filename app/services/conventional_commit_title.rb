# frozen_string_literal: true

class ConventionalCommitTitle
  CONVENTIONAL_PATTERN = /\A(?<type>feat|fix|perf|docs|refactor|ci|build|test|chore)(?<rest>(?:\([^)]+\))?!?: .+)\z/i
  FIX_LABEL_HINTS = %w[bug bugs fix regression hotfix security dependabot].freeze
  PREFIX_HINTS = [
    [ "fix", /\A(?:fix|resolve|correct|prevent|repair)\b/i ],
    [ "feat", /\A(?:add|implement|support|introduce|create|enable|allow)\b/i ],
    [ "docs", /\A(?:docs?|document|documentation|readme)\b/i ],
    [ "test", /\A(?:test|tests|spec|specs)\b/i ],
    [ "ci", /\A(?:ci|workflow|github action|actions)\b/i ],
    [ "build", /\A(?:build|bundler|rubygems|gemfile|docker(?:file| image)?)\b/i ],
    [ "refactor", /\A(?:refactor|cleanup|clean up|simplify|rename|extract|reorganize)\b/i ]
  ].freeze

  class << self
    def normalize(title)
      match = title.to_s.strip.match(CONVENTIONAL_PATTERN)
      return nil unless match

      "#{match[:type].downcase}#{match[:rest]}"
    end

    def for_issue(issue, fallback_type: nil, project: issue&.project, style_key: "commit_style")
      style_entry = style_entry_for(project, style_key)
      style = style_entry.fetch(:value)
      return plain_title_for(issue, style) if style["type"] == "plain"

      normalized = normalized_title_for(issue, style, style_entry:, style_key:)
      return normalized if normalized

      title = sanitize_subject(issue&.title)
      fallback_type = normalized_fallback_type(style, fallback_type: fallback_type)
      return "#{fallback_type}: apply agent changes" if title.blank?

      inferred_type = infer_type(issue, title: title, fallback_type: fallback_type)
      inferred_type = enforce_allowed_type(
        inferred_type,
        original_title: issue&.title,
        style: style,
        style_entry: style_entry,
        style_key: style_key
      )
      "#{inferred_type}: #{title}"
    end

    private

    def plain_title_for(issue, style)
      title = sanitize_subject(issue&.title)
      return title if title.present?

      style["fallback_subject"].presence || "Apply agent changes"
    end

    def style_entry_for(project, style_key)
      return default_style_entry(style_key) unless project

      ProjectConventions::AutomationProfile.for(project:).convention(style_key)
    end

    def default_style_entry(style_key)
      value = ProjectConventions::Catalog.default_for(style_key)

      {
        key: style_key,
        value: value,
        enabled: value.present?,
        source: value.present? ? "default" : "unset"
      }
    rescue ActiveRecord::ActiveRecordError => e
      Rails.logger.warn(
        message: "conventional_commit_title.style_lookup_failed",
        key: style_key,
        error: e.message
      )

      {
        key: style_key,
        value: ProjectConventions::Catalog.default_for(style_key),
        enabled: true,
        source: "default"
      }
    end

    def normalized_title_for(issue, style, style_entry:, style_key:)
      normalized = normalize(issue&.title)
      return unless normalized

      type = normalized[CONVENTIONAL_PATTERN, :type]&.downcase
      type = enforce_allowed_type(type, original_title: issue&.title, style:, style_entry:, style_key:) if type
      return normalized if type == normalized[CONVENTIONAL_PATTERN, :type]&.downcase

      title = sanitize_subject(issue&.title)
      return if title.blank?

      "#{type}: #{title}"
    end

    def normalized_fallback_type(style, fallback_type:)
      preferred = fallback_type.presence || style["default_type"].presence || "feat"
      allowed_types = Array(style["allowed_types"]).filter_map(&:presence)
      return preferred if allowed_types.empty? || allowed_types.include?(preferred)

      allowed_types.first
    end

    def infer_type(issue, title:, fallback_type:)
      labels = Array(issue&.labels).filter_map { |label| label.to_s.downcase.presence }
      return "fix" if (labels & FIX_LABEL_HINTS).any?

      PREFIX_HINTS.each do |type, pattern|
        return type if title.match?(pattern)
      end

      fallback_type
    end

    def enforce_allowed_type(type, original_title:, style:, style_entry:, style_key:)
      allowed_types = Array(style["allowed_types"]).filter_map(&:presence)
      return type if type.blank? || allowed_types.empty? || allowed_types.include?(type)

      Rails.logger.warn(
        message: "conventional_commit_title.disallowed_type",
        key: style_key,
        source: style_entry[:source],
        required: style.fetch("required", false),
        disallowed_type: type,
        allowed_types: allowed_types,
        title: original_title.to_s
      )

      return type unless style.fetch("required", false)

      normalized_fallback_type(style, fallback_type: type)
    end

    def sanitize_subject(title)
      title
        .to_s
        .strip
        .sub(/\A(?:fix|feature)\s+#\d+:\s*/i, "")
        .sub(/\A(?:bug|feature|chore|docs|test|refactor)\s*:\s*/i, "")
        .gsub(/\s+/, " ")
        .delete_suffix(".")
    end
  end
end
