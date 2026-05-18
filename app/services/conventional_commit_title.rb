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
      style = style_for(project, style_key)
      return plain_title_for(issue, style) if style["type"] == "plain"

      normalized = normalize(issue&.title)
      return normalized if normalized

      title = sanitize_subject(issue&.title)
      fallback_type ||= style["default_type"] || "feat"
      return "#{fallback_type}: apply agent changes" if title.blank?

      "#{infer_type(issue, title: title, fallback_type: fallback_type)}: #{title}"
    end

    private

    def plain_title_for(issue, style)
      title = sanitize_subject(issue&.title)
      return title if title.present?

      style["fallback_subject"].presence || "Apply agent changes"
    end

    def style_for(project, style_key)
      return default_style(style_key) unless project

      ProjectConventions::Resolve.call(project:, key: style_key).fetch(:value)
    rescue ActiveRecord::ActiveRecordError => e
      Rails.logger.warn(
        message: "conventional_commit_title.style_lookup_failed",
        key: style_key,
        error: e.message
      )
      default_style(style_key)
    end

    def default_style(style_key)
      ProjectConventions::Resolve::DEFAULTS.fetch(style_key, {})
    end

    def infer_type(issue, title:, fallback_type:)
      labels = Array(issue&.labels).filter_map { |label| label.to_s.downcase.presence }
      return "fix" if (labels & FIX_LABEL_HINTS).any?

      PREFIX_HINTS.each do |type, pattern|
        return type if title.match?(pattern)
      end

      fallback_type
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
