# frozen_string_literal: true

module ReleasePlease
  # Identifies and classifies release-please PRs by parsing the PR title
  # and comparing the target version against the current released version.
  #
  # A release-please PR is identified by:
  # - Author: github-actions[bot] (or a configured release-please app)
  # - Title: matches `chore(<branch>): release <version>`
  # - Label: `autorelease: pending`
  #
  # Returns a result struct with the parsed PR details and bump classification,
  # or nil if the PR is not a valid release-please PR.
  class ParseReleasePr
    TITLE_PATTERN = /\Achore\(.+\): release (?:\S+ )?(\d+\.\d+\.\d+)\z/
    RELEASE_PLEASE_AUTHORS = %w[github-actions[bot] release-please[bot]].freeze
    AUTORELEASE_LABEL = "autorelease: pending"

    Result = Struct.new(:pr_number, :new_version, :previous_version, :bump, keyword_init: true)

    class << self
      def call(pr_data:, previous_version:)
        return nil unless release_please_pr?(pr_data)

        new_version = parse_version(pr_data)
        return nil unless new_version

        bump = classify_bump(previous_version, new_version)
        return nil unless bump

        Result.new(
          pr_number: pr_data.number,
          new_version: new_version,
          previous_version: previous_version,
          bump: bump
        )
      end

      def release_please_pr?(pr_data)
        author = pr_data.user&.login || pr_data.dig(:user, :login)
        return false unless RELEASE_PLEASE_AUTHORS.include?(author)

        title = pr_data.title || pr_data[:title]
        return false unless title&.match?(TITLE_PATTERN)

        labels = extract_labels(pr_data)
        labels.include?(AUTORELEASE_LABEL)
      end

      private

      def extract_labels(pr_data)
        raw_labels = pr_data.labels || pr_data[:labels] || []
        raw_labels.map { |l| l.respond_to?(:name) ? l.name : (l[:name] || l["name"]) }.compact
      end

      def parse_version(pr_data)
        title = pr_data.title || pr_data[:title]
        match = title&.match(TITLE_PATTERN)
        match[1] if match
      end

      def classify_bump(previous_version_str, new_version_str)
        prev = parse_semver(previous_version_str)
        new_ver = parse_semver(new_version_str)
        return nil unless prev && new_ver

        if new_ver[0] > prev[0]
          "major"
        elsif new_ver[1] > prev[1]
          "minor"
        elsif new_ver[2] > prev[2]
          "patch"
        end
      end

      def parse_semver(version_str)
        return nil if version_str.blank?

        parts = version_str.to_s.split(".")
        return nil unless parts.length == 3

        parts.map(&:to_i)
      rescue ArgumentError
        nil
      end
    end
  end
end
