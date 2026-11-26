# frozen_string_literal: true

module Inbox
  # Projects the persisted feature-decision and readiness records into one
  # shared planning-hold explanation. It is deliberately read-only: response,
  # evidence, and release transitions retain their existing service boundaries.
  # @spec OPERATOR-INBOX-021
  class FeatureDecisionContext
    Decision = Data.define(:id, :kind, :prompt, :design_claim)
    Task = Data.define(:number, :title, :url)
    DesignRevision = Data.define(:number, :revision, :state, :url)
    Checkpoint = Data.define(:id, :status, :recommendation, :alternatives, :consequences, :affected_scope, :evidence,
      :proposed_design_revision, :proposed_acceptance_revision, :questions)
    Result = Data.define(:decisions, :tasks, :design_revisions, :next_actions, :checkpoints)

    def self.call(...) = new(...).call

    def initialize(feature_intent:, readiness: nil)
      @feature_intent = feature_intent
      @readiness = readiness || FeatureDecisionReadiness.call(feature_intent:)
    end

    def call
      Result.new(
        decisions: decisions,
        tasks: tasks,
        design_revisions: design_revisions,
        next_actions: readiness.human_actions,
        checkpoints: checkpoints
      )
    end

    private

    attr_reader :feature_intent, :readiness

    def decisions
      feature_intent.feature_intent_decisions.select(&:open?).map do |decision|
        Decision.new(id: decision.id, kind: decision.kind, prompt: decision.prompt, design_claim: decision.design_claim)
      end
    end

    # @spec PROJECT-DELEGATION-002
    def checkpoints
      questions = feature_intent.feature_intent_decisions.to_a.sort_by(&:id)
      ActiveRecord::Associations::Preloader.new(records: questions, associations: :intent_checkpoint).call
      questions.group_by(&:intent_checkpoint_id).filter_map do |id, questions|
        next if id.nil?

        checkpoint = questions.first.intent_checkpoint
        next unless checkpoint&.feature_intent_id == feature_intent.id

        attributes = checkpoint.attributes.symbolize_keys.slice(*(Checkpoint.members - [ :questions ]))
        Checkpoint.new(**attributes, questions: questions.map { |question| { id: question.id, prompt: question.prompt } })
      end
    end

    def tasks
      feature_intent.feature_intent_issues.filter_map do |link|
        next unless held?(link)

        issue = link.issue
        next unless issue

        Task.new(number: issue.github_number, title: issue.title, url: issue.github_url)
      end
    end

    def held?(link)
      return link.release_state != "released" if feature_intent.confidence_driven?

      !feature_intent.released? || feature_intent.approved_design_revision.blank?
    end

    def design_revisions
      feature_intent.feature_intent_design_prs.map do |design_pr|
        DesignRevision.new(
          number: design_pr.pull_request_number,
          revision: design_pr.head_sha,
          state: design_pr.merged? ? "merged" : (design_pr.stale? ? "stale" : "open"),
          url: design_pr.github_url
        )
      end
    end
  end
end
