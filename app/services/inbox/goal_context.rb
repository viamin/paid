# frozen_string_literal: true

module Inbox
  # Resolves persisted feature approval context for a decision brief. Queue
  # titles identify work, not agreed product intent. An issue may serve
  # several designs, so every current approved intent is preserved; approval
  # recency never selects an authoritative goal. The three presentation
  # branches stay explicit in one place, so this projection is intentionally
  # longer than a typical service object.
  # @spec OPERATOR-INBOX-027
  class GoalContext
    LinkedIntent = Data.define(:goal, :source, :revision)
    Result = Data.define(:goal, :source, :revision, :repository, :linked_intents)
    SEVERAL_INTENTS_GOAL = "This work item serves more than one approved feature intent."
    SEVERAL_INTENTS_SOURCE = "Several approved feature intents are linked to this work item"

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

      context_for(entry, features_for(entry))
    end

    # One batched lookup covers every issue-backed entry; a record-backed
    # entry resolves from its own feature record, matching `call`.
    def preload
      lookup = features_by_issue_id
      entries.each do |candidate|
        candidate.goal_context = context_for(candidate, features_for(candidate, lookup))
      end
    end

    private

    attr_reader :entries, :entry

    def features_for(candidate, lookup = {})
      record = feature_record(candidate)
      return [ record ] if record

      issue_id = linked_issue_id(candidate)
      return [] unless issue_id

      lookup[issue_id] || linked_features([ issue_id ]).to_a
    end

    # Every queried issue id maps to a list (possibly empty), so a batched
    # preload never falls back to a per-entry query.
    def features_by_issue_id
      issue_ids = linked_issue_ids
      return {} if issue_ids.empty?

      linked_features(issue_ids).each_with_object(issue_ids.index_with { [] }) do |feature, features|
        feature.feature_intent_issues.each { |link| (features[link.issue_id] ||= []) << feature }
      end
    end

    def linked_issue_ids
      @linked_issue_ids ||= entries.filter_map { |candidate| linked_issue_id(candidate) }.uniq
    end

    # Creation order keeps the preserved list deterministic without ranking
    # one approved design above another.
    def linked_features(issue_ids)
      FeatureIntent.linked_to_issue_ids(issue_ids).order(:id)
    end

    def feature_record(candidate)
      candidate.record if candidate.feature_decision? && candidate.record.is_a?(FeatureIntent)
    end

    def linked_issue_id(candidate)
      candidate.issue && (candidate.issue.parent_issue_id || candidate.issue.id)
    end

    def context_for(candidate, features)
      approved = Array(features).select { |feature| feature.released? && feature.approved_design_revision.present? }
      return unavailable(candidate, feature: Array(features).first) if approved.empty?
      return single(candidate, approved.first) if approved.one?

      several(candidate, approved)
    end

    def single(candidate, feature)
      intent = linked_intent_for(feature)
      Result.new(goal: intent.goal, source: intent.source, revision: intent.revision,
        repository: candidate.project.full_name, linked_intents: [ intent ])
    end

    # No persisted ownership or supersession relationship ranks concurrent
    # approved designs, so the brief discloses each one instead of electing a
    # goal by approval recency.
    def several(candidate, approved)
      Result.new(
        goal: SEVERAL_INTENTS_GOAL,
        source: SEVERAL_INTENTS_SOURCE,
        revision: nil,
        repository: candidate.project.full_name,
        linked_intents: approved.map { |feature| linked_intent_for(feature) }
      )
    end

    def linked_intent_for(feature)
      LinkedIntent.new(
        goal: feature.brief.presence || feature.title,
        source: "Approved feature intent: #{feature.title}",
        revision: feature.approved_design_revision
      )
    end

    def unavailable(candidate, feature: nil)
      Result.new(
        goal: "No approved intent is available for this work item.",
        source: feature ? "Feature intent is not approved" : "Intent unavailable",
        revision: nil,
        repository: candidate.project.full_name,
        linked_intents: []
      )
    end
  end
end
