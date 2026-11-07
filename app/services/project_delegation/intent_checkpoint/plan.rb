# frozen_string_literal: true

module ProjectDelegation
  module IntentCheckpoint
    # Builds the reviewable intent checkpoint for one work item (RDR-080):
    # groups related material product questions and presents each group's
    # question(s), recommendation, alternatives, consequences, affected
    # scope, and evidence, then surfaces one Inbox request for settlement.
    # Questions come either from an explicit payload (agent-emitted material
    # questions) or from the work item's open RDR-066 feature-intent
    # decisions; this slice never re-assesses confidence or approval.
    # @spec PROJECT-DELEGATION-002
    class Plan
      NOTIFICATION_SOURCE = "project_delegation_intent_checkpoint"
      NO_RECOMMENDATION = "Human decision required; no recommendation recorded yet."

      def self.call(...)
        new(...).call
      end

      def self.pending_for(issue)
        issue.intent_checkpoints.pending.latest_first.first
      end

      def initialize(issue:, questions: nil)
        @issue = issue
        @questions = questions
      end

      def call
        payloads = question_payloads
        return nil if payloads.empty?

        checkpoint = persist!(payloads)
        publish_request(checkpoint)
        checkpoint
      end

      private

      attr_reader :issue, :questions

      def question_payloads
        return derive_from_decisions if questions.nil?

        questions.map { |question| normalize_explicit(question) }
      end

      def normalize_explicit(question)
        payload = question.to_h.deep_stringify_keys
        text = payload["question"].to_s.strip
        scope = payload["affected_scope"].to_s.strip
        raise ArgumentError, "each material question needs a question" if text.empty?
        raise ArgumentError, "each material question needs an affected_scope" if scope.empty?

        payload.merge("question" => text, "affected_scope" => scope)
      end

      # Consume the existing RDR-066 decision records instead of duplicating
      # them: every still-open decision for a design this issue serves
      # becomes one material question on the checkpoint.
      def derive_from_decisions
        decisions = FeatureIntentDecision.open_decisions
          .where(feature_intent: linked_feature_intents)
          .order(:id)
        decisions.map { |decision| payload_for_decision(decision) }
      end

      def linked_feature_intents
        FeatureIntent.joins(:feature_intent_issues)
          .where(feature_intent_issues: { issue_id: issue.id })
      end

      def payload_for_decision(decision)
        {
          "question" => decision.prompt.to_s.strip,
          "affected_scope" => decision.design_claim.to_s.strip,
          "recommendation" => recommendation_for_decision(decision),
          "evidence" => decision.source_agent_run_id ? [ "agent_run:#{decision.source_agent_run_id}" ] : [],
          "source_decision_ids" => [ decision.id ],
          "feature_intent_id" => decision.feature_intent_id
        }
      end

      def recommendation_for_decision(decision)
        return decision.prompt if decision.inferred_decision?

        NO_RECOMMENDATION
      end

      # Group related questions: every question touching the same affected
      # scope becomes one reviewable group with a stable key, shared
      # recommendation, and the union of alternatives, consequences, and
      # evidence.
      def persist!(payloads, attempts = 0)
        groups = build_groups(payloads)
        issue.transaction do
          supersede_pending
          issue.intent_checkpoints.create!(
            account: issue.project.account,
            project: issue.project,
            groups: groups,
            feature_intent_id: first_feature_intent_id(payloads)
          )
        end
      rescue ActiveRecord::RecordNotUnique
        # A concurrent plan won the one-pending-slot race; reuse its slot so
        # the work item still ends with exactly one pending checkpoint.
        raise if attempts >= 3

        persist!(payloads, attempts + 1)
      end

      def build_groups(payloads)
        payloads.group_by { |payload| payload["affected_scope"].to_s.downcase.strip }
          .values.map { |group_payloads| build_group(group_payloads) }
      end

      def build_group(group_payloads)
        scope = group_payloads.first["affected_scope"]
        {
          "key" => scope.downcase.parameterize,
          "affected_scope" => scope,
          "questions" => group_payloads.map { |payload| payload["question"] }.uniq,
          "recommendation" => group_payloads.filter_map { |payload| payload["recommendation"].presence }.first || NO_RECOMMENDATION,
          "alternatives" => merge_fields(group_payloads, "alternatives"),
          "consequences" => merge_fields(group_payloads, "consequences"),
          "evidence" => merge_fields(group_payloads, "evidence"),
          "source_decision_ids" => group_payloads.flat_map { |payload| payload["source_decision_ids"] }.compact.uniq
        }.compact
      end

      def merge_fields(payloads, field)
        payloads.flat_map { |payload| Array(payload[field]) }.map(&:to_s).reject(&:blank?).uniq
      end

      def first_feature_intent_id(payloads)
        payloads.filter_map { |payload| payload["feature_intent_id"] }.first
      end

      def supersede_pending
        self.class.pending_for(issue)&.update!(status: "superseded")
      end

      def publish_request(checkpoint)
        Notifications::Publish.call(
          account: checkpoint.account,
          source: NOTIFICATION_SOURCE,
          subject: issue,
          severity: :error,
          blocking: true,
          nav_section: "projects",
          title: "Material questions need one settlement",
          description: "#{checkpoint.groups.size} grouped material question#{checkpoint.groups.size == 1 ? "" : "s"} must be settled before downstream work continues.",
          metadata: request_metadata(checkpoint)
        )
      end

      def request_metadata(checkpoint)
        {
          "checkpoint_id" => checkpoint.id,
          "groups" => checkpoint.groups.map { |group| group.slice("key", "questions", "recommendation", "alternatives", "consequences", "affected_scope", "evidence") },
          "proposed_revision" => Revisions.for(issue)
        }
      end
    end
  end
end
