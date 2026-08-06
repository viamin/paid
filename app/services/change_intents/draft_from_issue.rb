# frozen_string_literal: true

module ChangeIntents
  # Creates an issue-linked draft Change Intent Record from an LLM-produced
  # payload. The semantic judgment of whether an issue contains a non-obvious
  # constraint or rejected alternative worth preserving lives in the issue
  # enhancement prompt (ZFC); this service is the mechanical persistence step.
  #
  # A draft is created only when the payload carries a usable title and intent,
  # and at most one draft is kept per issue so re-evaluation rounds do not
  # accumulate duplicates. Drafts remain `draft` until a human approves them
  # through the review path, so they never enter the knowledge pipeline on
  # their own.
  class DraftFromIssue
    def self.call(...)
      new(...).call
    end

    def initialize(project:, issue:, payload:)
      @project = project
      @issue = issue
      @payload = payload
    end

    # @spec CHANGE-INTENT-004
    def call
      return unless cir_worthy?

      existing_draft || create_draft
    end

    private

    attr_reader :project, :issue, :payload

    def cir_worthy?
      return false unless payload.is_a?(Hash)

      title.present? && intent.present?
    end

    def existing_draft
      issue&.change_intents&.draft&.first
    end

    def create_draft
      ChangeIntent.create!(
        project: project,
        issue: issue,
        title: title,
        intent: intent,
        behavior: clean(payload[:behavior]),
        constraints: clean(payload[:constraints]),
        decisions_made: clean(payload[:decisions_made]),
        status: "draft"
      )
    end

    def title
      @title ||= clean(payload[:title])&.truncate(500)
    end

    def intent
      @intent ||= clean(payload[:intent])
    end

    def clean(value)
      value.to_s.strip.presence
    end
  end
end
