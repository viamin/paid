# frozen_string_literal: true

module Inbox
  # Resolves persisted feature approval context for a decision brief. Queue
  # titles identify work, not agreed product intent.
  # @spec OPERATOR-INBOX-027
  class GoalContext
    Result = Data.define(:goal, :source, :revision, :repository)

    def self.call(entry:)
      new(entry:).call
    end

    def self.preload(entries:)
      new(entries:).preload
    end

    def initialize(entry: nil, entries: nil)
      @entry = entry
      @entries = entries
    end

    def call
      return entry.goal_context if entry.goal_context

      context_for(entry, feature_for(entry))
    end

    def preload
      features_by_issue_id.each do |issue_id, feature|
        entries.select { |candidate| linked_issue_id(candidate) == issue_id }.each do |candidate|
          candidate.goal_context = context_for(candidate, feature)
        end
      end
      entries.each { |candidate| candidate.goal_context ||= context_for(candidate, feature_record(candidate)) }
    end

    private

    attr_reader :entries, :entry

    def features_by_issue_id
      issue_ids = entries.filter_map { |candidate| linked_issue_id(candidate) }.uniq
      return {} if issue_ids.empty?

      FeatureIntent.linked_to_issue_ids(issue_ids).order(approved_revision_recorded_at: :desc, id: :desc)
        .group_by { |feature| feature.feature_intent_issues.first.issue_id }
        .transform_values(&:first)
    end

    def feature_for(candidate)
      return feature_record(candidate) if feature_record(candidate)

      issue_id = linked_issue_id(candidate)
      return unless issue_id

      FeatureIntent.linked_to_issue_ids([ issue_id ]).order(approved_revision_recorded_at: :desc, id: :desc).first
    end

    def feature_record(candidate)
      candidate.record if candidate.feature_decision? && candidate.record.is_a?(FeatureIntent)
    end

    def linked_issue_id(candidate)
      candidate.issue && (candidate.issue.parent_issue_id || candidate.issue.id)
    end

    def context_for(candidate, feature)
      return unavailable(candidate) unless feature&.approved_design_revision.present?

      Result.new(
        goal: feature.brief.presence || feature.title,
        source: "Approved feature intent: #{feature.title}",
        revision: feature.approved_design_revision,
        repository: candidate.project.full_name
      )
    end

    def unavailable(candidate)
      Result.new(
        goal: "No approved intent is available for this work item.",
        source: feature_record(candidate) ? "Feature intent is not approved" : "Intent unavailable",
        revision: nil,
        repository: candidate.project.full_name
      )
    end
  end
end
