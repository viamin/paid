# frozen_string_literal: true

module PartialCloseouts
  # Rechecks explicitly recorded external prerequisite occurrences against the
  # account-scoped issue mirror. Human evidence is intentionally not inferred
  # from an external transition.
  class ExternalPrerequisites
    RESOLVED_PAID_STATES = Issue::NON_BLOCKING_OPEN_DEPENDENCY_STATES.freeze

    def self.call(...) = new(...).call

    def self.status_for(issue, dependency)
      new(issue).status_for(issue, dependency)
    end

    def self.recheck(notification)
      new(notification.subject).send(:refresh, notification)
    end

    def self.states_for(notification)
      new(notification.subject).states_for(notification)
    end

    def self.human_evidence_required?(notification)
      new(notification.subject).human_evidence_required?(notification)
    end

    def initialize(target)
      @target = target
    end

    def call # @spec PARTIAL-CLOSEOUT-037
      return [] unless target.project

      matching_notifications.filter_map { |notification| refresh(notification) }
    end

    def status_for(issue, dependency)
      reference = reference_for(dependency)
      target_issue = target_for(issue, dependency)
      return unavailable_status(reference) unless target_issue

      state = resolved?(target_issue) ? "resolved" : target_issue.github_state
      {
        "reference" => reference, "state" => state, "owner" => target_issue.github_creator_login,
        "url" => target_issue.github_url,
        "recovery" => recovery_for(state)
      }.compact
    end

    def states_for(notification)
      external_occurrences(notification).map do |occurrence|
        status_for(notification.subject, occurrence.fetch("external_dependency"))
      end
    end

    def human_evidence_required?(notification)
      occurrences = PrerequisiteOccurrences.for(notification)
      return false if legacy_external_dependency(notification, occurrences)
      return true if occurrences.empty?

      occurrences.any? { |occurrence| occurrence["kind"] != "external" }
    end

    private

    attr_reader :target

    def matching_notifications
      Notification.active.where(source: PREREQUISITE_NOTIFICATION_SOURCE, subject_type: "Issue",
        subject_id: dependent_issue_ids).includes(subject: :project)
    end

    def dependent_issue_ids
      IssueDependency.joins(issue: :project)
        .where(projects: { account_id: target.project.account_id })
        .where(depends_on_owner: target.project.owner.to_s.downcase,
          depends_on_repo: target.project.repo.to_s.downcase, depends_on_number: target.github_number)
        .pluck(:issue_id)
    end

    def refresh(notification)
      notification.with_lock do
        return unless notification.active?

        upgrade_legacy_external_occurrence!(notification)
        states = external_occurrences(notification).index_with do |occurrence|
          status_for(notification.subject, occurrence.fetch("external_dependency"))
        end
        persist_states(notification, states)
        return unless states.values.all? { |state| state.fetch("state") == "resolved" }
        return unless human_occurrences_sufficient?(notification)

        notification.update!(resolved_at: Time.current,
          metadata: notification.metadata.merge("external_prerequisite_states" => states,
            "released_by" => "external_prerequisite", "released_at" => Time.current.iso8601))
      end
    end

    def external_occurrences(notification)
      occurrences = PrerequisiteOccurrences.for(notification)
      external = occurrences.select { |occurrence| occurrence["kind"] == "external" }
      return external if external.any?

      dependency = legacy_external_dependency(notification, occurrences)
      dependency ? [ { "external_dependency" => dependency } ] : []
    end

    def upgrade_legacy_external_occurrence!(notification)
      occurrences = PrerequisiteOccurrences.for(notification)
      dependency = legacy_external_dependency(notification, occurrences)
      return unless dependency

      occurrence = occurrences.first.to_h.merge("kind" => "external", "external_dependency" => dependency)
      notification.update!(metadata: notification.metadata.merge("prerequisites" => [ occurrence ]))
    end

    def legacy_external_dependency(notification, occurrences)
      return unless occurrences.size <= 1
      return unless notification.metadata["policy_selection"].blank? && notification.metadata["references"].blank?
      return unless notification.metadata["evidence_submissions"].blank?

      dependencies = notification.subject.issue_dependencies.where.not(depends_on_owner: nil).to_a
      return unless dependencies.one?

      dependency = dependencies.sole
      return unless [ notification.title, notification.description ].join(" ").include?("##{dependency.depends_on_number}")

      { "owner" => dependency.depends_on_owner, "repo" => dependency.depends_on_repo,
        "number" => dependency.depends_on_number }
    end

    def persist_states(notification, states)
      return if states.empty? || notification.metadata["external_prerequisite_states"] == states

      notification.update!(metadata: notification.metadata.merge("external_prerequisite_states" => states))
    end

    def human_occurrences_sufficient?(notification)
      PrerequisiteOccurrences.for(notification).reject { |occurrence| occurrence["kind"] == "external" }.all? do |occurrence|
        current_human_submission?(notification, occurrence)
      end
    end

    def current_human_submission?(notification, occurrence)
      source_revision = occurrence["source_revision"]
      return false if source_revision.present? && source_revision != Assessment.source_revision_for(notification.subject)

      Array(notification.metadata["evidence_submissions"]).reverse.any? do |submission|
        submission["prerequisite_identity"] == occurrence["identity"] &&
          submission["source_revision"] == source_revision && submission["outcome"] == "sufficient"
      end
    end

    def target_for(issue, dependency)
      owner = dependency.fetch("owner").to_s.downcase
      repo = dependency.fetch("repo").to_s.downcase
      project = issue.project.account.projects.find_by("LOWER(owner) = ? AND LOWER(repo) = ?", owner, repo)
      project&.issues&.find_by(github_number: dependency.fetch("number"))
    end

    def resolved?(issue)
      issue.github_state != "open" || issue.paid_state.in?(RESOLVED_PAID_STATES)
    end

    def reference_for(dependency)
      [ dependency.fetch("owner"), dependency.fetch("repo") ].join("/") + "#" + dependency.fetch("number").to_s
    end

    def unavailable_status(reference)
      { "reference" => reference, "state" => "unavailable",
        "url" => "https://github.com/#{reference.split('#').first}/issues/#{reference.split('#').last}",
        "recovery" => "Wait for the dependency repository to sync, then recheck this prerequisite." }
    end

    def recovery_for(state)
      return "Wait for the external work to resolve; Paid rechecks after the next sync." unless state == "unavailable"

      "Wait for the dependency repository to sync, then recheck this prerequisite."
    end
  end
end
