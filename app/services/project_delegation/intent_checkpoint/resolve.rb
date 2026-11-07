# frozen_string_literal: true

module ProjectDelegation
  module IntentCheckpoint
    # Focused re-decision routing for settled intent (RDR-080): downstream
    # callers ask whether a material question is already settled. A settled
    # checkpoint whose bound design and acceptance revisions are still
    # current answers the question; it is never asked again downstream. Only
    # evidence that conflicts with, invalidates, or materially expands the
    # bound revision — a changed revision token — routes one narrow Inbox
    # re-decision naming the smallest affected group, leaving unrelated
    # settled questions closed.
    # @spec PROJECT-DELEGATION-002
    class Resolve
      NOTIFICATION_SOURCE = "intent_checkpoint_redecision"

      Result = Data.define(:status, :answer, :checkpoint, :notification, :reasons) do
        def answered? = status == :answered
        def re_decision? = status == :re_decision
        def unsettled? = status == :unsettled
      end

      def self.call(...)
        new(...).call
      end

      def initialize(issue:, question: nil, group_key: nil)
        @issue = issue
        @question = question.to_s
        @group_key = group_key.to_s.presence
      end

      def call
        return unsettled unless checkpoint

        reasons = stale_reasons
        return answered if reasons.empty?

        route_re_decision(reasons)
      end

      private

      attr_reader :issue, :question, :group_key

      def checkpoint
        return @checkpoint if defined?(@checkpoint)

        @checkpoint = issue.intent_checkpoints.terminal.latest_first.find do |candidate|
          covers?(candidate)
        end
      end

      def covers?(candidate)
        group_key ? candidate.group_keys.include?(group_key) : candidate.covers_question?(question)
      end

      def answered
        Result.new(status: :answered, answer: checkpoint.answer_for(matched_group["key"]),
          checkpoint:, notification: nil, reasons: [])
      end

      def matched_group
        return checkpoint.group_for(group_key) if group_key

        checkpoint.groups.find { |candidate| Array(candidate["questions"]).include?(question) }
      end

      # A changed revision token is deterministic proof that the settled
      # revision was conflicted with, invalidated, or materially expanded.
      def stale_reasons
        current = Revisions.for(issue)
        [].tap do |reasons|
          reasons << "design_revision" if current["design_revision"] != checkpoint.design_revision
          reasons << "acceptance_revision" if current["acceptance_revision"] != checkpoint.acceptance_revision
        end
      end

      def route_re_decision(reasons)
        notification = Automation::FocusedDecision.call(
          account: checkpoint.account,
          subject: issue,
          source: NOTIFICATION_SOURCE,
          title: "Settled question needs a re-decision",
          description: "Evidence changed under the settled intent checkpoint; one focused decision is required before downstream work continues.",
          metadata: {
            "boundary" => "intent_checkpoint",
            "reasons" => reasons,
            "checkpoint_id" => checkpoint.id,
            "group_key" => matched_group["key"],
            "affected_scope" => matched_group["affected_scope"],
            "questions" => matched_group["questions"]
          }
        )
        Result.new(status: :re_decision, answer: nil, checkpoint:, notification:, reasons:)
      end

      def unsettled
        Result.new(status: :unsettled, answer: nil, checkpoint: nil, notification: nil, reasons: [])
      end
    end
  end
end
