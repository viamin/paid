# frozen_string_literal: true

module Projects
  # Removes only labels from the provisioned Paid catalog.  Label definitions
  # and every label outside that catalog are intentionally untouched.
  # @spec LABEL-INTEGRATION-006 LABEL-INTEGRATION-007
  class CleanupPaidLabels
    Entry = Data.define(:issue_id, :number, :labels)
    Result = Data.define(:entries, :removed, :failed)

    def self.preview(...) = new(...).preview
    def self.execute(...) = new(...).execute

    def initialize(project:)
      @project = project
    end

    def preview
      validate_mode!
      Result.new(entries: entries, removed: [], failed: [])
    end

    def execute
      validate_mode!
      entries.reduce(Result.new(entries: entries, removed: [], failed: [])) { |result, entry| remove(entry, result) }
    end

    private

    attr_reader :project

    def entries
      @entries ||= project.issues.where(github_state: "open").find_each.filter_map do |issue|
        labels = issue.labels & owned_labels
        Entry.new(issue_id: issue.id, number: issue.github_number, labels:) if labels.any?
      end
    end

    def owned_labels
      @owned_labels ||= EnsureStandardLabels.owned_label_names(project:)
    end

    def validate_mode!
      return unless project.label_integration_mode == "read_write"

      raise ArgumentError, "Paid labels cannot be cleaned up while label integration is read & write"
    end

    def remove(entry, result)
      client = project.label_cleanup_client
      raise GithubClient::Error, missing_credential_message if client.nil?

      response = client.remove_labels_from_issue(project.full_name, entry.number, entry.labels)
      persist_removal(entry, response[:removed])
      Result.new(entries: result.entries, removed: result.removed + response[:removed], failed: result.failed + response[:failed])
    end

    def missing_credential_message
      "Project has no usable GitHub credential — re-link the token or GitHub App installation before cleaning up Paid labels."
    end

    def persist_removal(entry, removed)
      return if removed.empty?

      issue = project.issues.find(entry.issue_id)
      issue.update_columns(labels: issue.labels - removed, updated_at: Time.current)
    end
  end
end
