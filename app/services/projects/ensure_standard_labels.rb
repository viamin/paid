# frozen_string_literal: true

module Projects
  # Ensures that the project's configured standard labels exist on the connected
  # GitHub repository. Creates missing labels and flags existing labels whose
  # color or description diverge from Paid defaults.
  #
  # Standard labels include:
  # - generated_label_name  (e.g. "paid-generated")
  # - automation_label_name (e.g. "paid-automation")
  # - Priority labels       (P1, P2, P3 by default)
  #
  # @example
  #   result = Projects::EnsureStandardLabels.call(project: project)
  #   result.created   # => ["paid-generated", "P1"]
  #   result.existing  # => ["paid-automation"]
  #   result.divergent # => [{ name: "P2", field: "color", expected: "ff9800", actual: "000000" }]
  #   result.errors    # => []
  class EnsureStandardLabels
    LABEL_DEFINITIONS = {
      generated: { color: "0e8a16", description: "Created by Paid" },
      automation: { color: "1d76db", description: "Triggers Paid automation" },
      priority: {
        "P1" => { color: "d93f0b", description: "High priority" },
        "P2" => { color: "ff9800", description: "Medium priority" },
        "P3" => { color: "fbca04", description: "Low priority" }
      }
    }.freeze

    attr_reader :project

    def initialize(project:)
      @project = project
    end

    def self.call(...)
      new(...).call
    end

    def call
      client = project.github_token.client
      repo = project.full_name

      remote_labels = fetch_remote_labels(client, repo)
      remote_by_name = remote_labels.each_with_object({}) do |label, h|
        h[label.name.downcase] = label
      end

      created = []
      existing = []
      divergent = []
      errors = []

      expected_labels.each do |expected|
        remote = remote_by_name[expected[:name].downcase]

        if remote.nil?
          create_label(client, repo, expected, created, errors)
        else
          existing << expected[:name]
          check_divergence(remote, expected, divergent)
        end
      end

      log_result(created, existing, divergent, errors)

      Result.new(created: created, existing: existing, divergent: divergent, errors: errors)
    end

    private

    def expected_labels
      labels = []

      labels << {
        name: project.generated_label_name,
        color: LABEL_DEFINITIONS[:generated][:color],
        description: LABEL_DEFINITIONS[:generated][:description]
      }

      labels << {
        name: project.automation_label_name,
        color: LABEL_DEFINITIONS[:automation][:color],
        description: LABEL_DEFINITIONS[:automation][:description]
      }

      project.effective_priority_labels.each do |tier, label_name|
        defaults = LABEL_DEFINITIONS[:priority][tier] || {}
        labels << {
          name: label_name,
          color: defaults[:color] || "ededed",
          description: defaults[:description] || "Priority #{tier}"
        }
      end

      labels
    end

    def fetch_remote_labels(client, repo)
      client.labels(repo)
    rescue GithubClient::ApiError => e
      if e.status == 403
        raise GithubClient::ApiError.new(
          "Insufficient permissions to read labels. Ensure the GitHub token has repo scope.",
          status: 403
        )
      end
      raise
    end

    def create_label(client, repo, expected, created, errors)
      client.create_label(repo, name: expected[:name], color: expected[:color], description: expected[:description])
      created << expected[:name]
    rescue GithubClient::ApiError => e
      if e.status == 422
        # Label was created between our fetch and create — treat as existing
        return
      end
      if e.status == 403
        errors << { name: expected[:name], error: "Insufficient permissions to create labels. Ensure the GitHub token has repo scope." }
      else
        errors << { name: expected[:name], error: e.message }
      end
    end

    def check_divergence(remote, expected, divergent)
      remote_color = remote.color.to_s.delete_prefix("#").downcase
      expected_color = expected[:color].to_s.delete_prefix("#").downcase

      if remote_color != expected_color
        divergent << { name: expected[:name], field: "color", expected: expected_color, actual: remote_color }
      end

      remote_desc = remote.respond_to?(:description) ? remote.description.to_s : ""
      if expected[:description].present? && remote_desc != expected[:description]
        divergent << { name: expected[:name], field: "description", expected: expected[:description], actual: remote_desc }
      end
    end

    def log_result(created, existing, divergent, errors)
      Rails.logger.info(
        message: "github_sync.ensure_standard_labels",
        project_id: project.id,
        repo: project.full_name,
        created: created,
        existing: existing,
        divergent_count: divergent.size,
        error_count: errors.size
      )
    end

    # Result object returned by EnsureStandardLabels.
    class Result
      attr_reader :created, :existing, :divergent, :errors

      def initialize(created:, existing:, divergent:, errors:)
        @created = created
        @existing = existing
        @divergent = divergent
        @errors = errors
      end

      def notice_message
        parts = []
        parts << "Created labels: #{created.join(', ')}." if created.any?
        parts << "#{existing.size} label(s) already present." if existing.any?
        if divergent.any?
          names = divergent.map { |d| d[:name] }.uniq
          parts << "Labels with different settings: #{names.join(', ')}."
        end
        if errors.any?
          names = errors.map { |e| e[:name] }
          parts << "Failed to create: #{names.join(', ')}."
        end
        parts.join(" ").presence || "All standard labels are up to date."
      end

      def any_errors?
        errors.any?
      end
    end
  end
end
