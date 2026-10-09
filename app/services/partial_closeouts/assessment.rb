# frozen_string_literal: true

require "digest"

module PartialCloseouts
  # Presents a persisted semantic closeout assessment alongside current,
  # deterministic evidence. It deliberately never reassesses on an Inbox read:
  # stale means the operator can see that a bounded audit is needed, not that
  # current implementation or a closed child completed a criterion.
  # @spec PARTIAL-CLOSEOUT-023
  class Assessment
    Result = Data.define(:assessment, :criteria, :source_revision, :intent_revision, :assessed_at, :stale, :next_action) do
      def stale? = stale
    end

    def self.call(...) = new(...).call

    def self.snapshot(agent_run, assessment)
      assessment.to_h.deep_stringify_keys.merge(
        "source_revision" => Issues::CloseoutEvidence.call(agent_run.issue).digest,
        "intent_revision" => intent_revision_for(agent_run.issue),
        "assessed_at" => Time.current.iso8601
      )
    end

    def self.intent_revision_for(issue)
      Digest::SHA256.hexdigest([ issue.title, issue.body ].map(&:to_s).join("\0"))
    end

    def initialize(issue)
      @issue = issue
    end

    def call
      Result.new(
        assessment: assessment,
        criteria: criteria,
        source_revision: assessment["source_revision"],
        intent_revision: assessment["intent_revision"],
        assessed_at: assessment["assessed_at"],
        stale: stale?,
        next_action: next_action
      )
    end

    private

    attr_reader :issue

    def assessment
      @assessment ||= latest_run&.reconciliation.to_h.fetch("assessment", {}).deep_stringify_keys || {}
    end

    def latest_run
      @latest_run ||= issue.agent_runs.where("reconciliation ? 'assessment'").order(id: :desc).first
    end

    def criteria
      @criteria ||= raw_criteria.map { |criterion| present_criterion(criterion) }
    end

    def raw_criteria
      criteria = assessment["criteria"]
      return criteria if criteria.is_a?(Array)

      Array(assessment["gaps"]).map { |gap| gap.merge("state" => "unmet") }
    end

    def present_criterion(criterion)
      criterion.merge("state" => valid_state(criterion["state"]), "owner" => owner_for(criterion)).compact
    end

    def valid_state(state)
      %w[satisfied unmet unknown].include?(state) ? state : "unknown"
    end

    def owner_for(criterion)
      number = criterion["owner_issue_number"].to_i
      return if number.zero?

      owner = owners_by_number[number]
      { "number" => number, "url" => owner&.github_url, "open" => owner&.github_state == "open" }
    end

    def owners_by_number
      @owners_by_number ||= issue.project.issues.where(github_number: owner_numbers).index_by(&:github_number)
    end

    def owner_numbers
      raw_criteria.filter_map { |criterion| criterion["owner_issue_number"].to_i.presence }
    end

    def stale?
      assessment.blank? || assessment["source_revision"] != current_source_revision || assessment["intent_revision"] != self.class.intent_revision_for(issue)
    end

    def current_source_revision
      @current_source_revision ||= Issues::CloseoutEvidence.call(issue).digest
    end

    def next_action
      return { "kind" => "fresh_audit", "explanation" => "The recorded assessment is stale; request a bounded acceptance audit before treating work as complete." } if stale?

      persisted = assessment["next_action"].to_h.deep_stringify_keys
      return persisted if persisted["kind"].present? && persisted["explanation"].present?

      inferred_next_action
    end

    def inferred_next_action
      if criteria.any? { |criterion| criterion["prerequisite_kind"].in?(%w[human external]) }
        { "kind" => "supply_evidence", "explanation" => "Human or external evidence is required before another agent run can help." }
      elsif criteria.any? { |criterion| criterion.dig("owner", "open") }
        { "kind" => "wait_for_owner", "explanation" => "Open follow-up work already owns the remaining criterion; another run would duplicate it." }
      elsif criteria.any? { |criterion| criterion["state"] == "unmet" }
        { "kind" => "continue_implementation", "explanation" => "No current owner covers the unmet implementation work." }
      else
        { "kind" => "fresh_audit", "explanation" => "Missing criterion evidence is not completion; request a bounded acceptance audit." }
      end
    end
  end
end
