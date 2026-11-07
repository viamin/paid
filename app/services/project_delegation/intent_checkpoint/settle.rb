# frozen_string_literal: true

module ProjectDelegation
  module IntentCheckpoint
    # Records the human settlement of an intent checkpoint: settle, reject,
    # or amend. The resulting answers are bound to the checkpoint's design
    # and acceptance revisions on an append-only settlement row, so the
    # binding can never be rewritten — a changed mind or a changed revision
    # opens a new checkpoint cycle. Settlement authority follows the RDR-066
    # threshold: any project member who may manage issue comments may settle
    # material intent.
    # @spec PROJECT-DELEGATION-002
    class Settle
      class Error < StandardError; end
      class NotPending < Error; end
      class PermissionDenied < Error; end
      class InvalidSettlement < Error; end

      def self.call(...)
        new(...).call
      end

      def initialize(checkpoint:, actor:, disposition:, answers: [])
        @checkpoint = checkpoint
        @actor = actor
        @disposition = disposition.to_s
        @answers = Array(answers)
      end

      def call
        validate!
        settlement = record_settlement
        resolve_request
        settlement
      end

      private

      attr_reader :checkpoint, :actor, :disposition, :answers

      def validate!
        raise NotPending, "checkpoint is #{checkpoint.status}, not pending" unless checkpoint.pending?
        raise PermissionDenied, "actor cannot settle intent for this project" unless authorized?
        raise InvalidSettlement, "disposition must be settled, rejected, or amended" unless disposition.in?(DelegationIntentSettlement::DISPOSITIONS)
        raise InvalidSettlement, "answers are required to settle or amend" if answers_required? && normalized_answers.empty?
        raise InvalidSettlement, "answers must not accompany a rejection" if disposition == "rejected" && normalized_answers.any?
        raise InvalidSettlement, "answers must address the checkpoint's groups" unless answered_group_keys.all? { |key| known_group_keys.include?(key) }
      end

      def authorized?
        ProjectPolicy.new(actor, checkpoint.project).settle_intent_checkpoint?
      end

      def answers_required?
        disposition.in?(%w[settled amended])
      end

      def record_settlement
        settlement = nil
        checkpoint.with_lock do
          raise NotPending, "checkpoint is #{checkpoint.status}, not pending" unless checkpoint.reload.pending?

          settlement = DelegationIntentSettlement.create!(
            delegation_intent_checkpoint: checkpoint,
            disposition: disposition,
            answers: normalized_answers,
            design_revision: checkpoint.design_revision,
            acceptance_revision: checkpoint.acceptance_revision,
            settled_by: actor,
            settled_at: Time.current
          )
          checkpoint.update!(status: status_after_settlement)
          Audit::RecordEvent.call(
            action: "project_delegation.intent_checkpoint_settled",
            actor: actor,
            subject: checkpoint.issue,
            metadata: {
              "checkpoint_id" => checkpoint.id,
              "settlement_id" => settlement.id,
              "disposition" => disposition,
              "design_revision" => checkpoint.design_revision,
              "acceptance_revision" => checkpoint.acceptance_revision
            }
          )
        end
        settlement
      end

      def status_after_settlement
        disposition == "rejected" ? "rejected" : "settled"
      end

      def resolve_request
        Notifications::Resolve.call(
          account: checkpoint.account,
          source: Open::NOTIFICATION_SOURCE,
          subject: checkpoint.issue
        )
      end

      def normalized_answers
        @normalized_answers ||= answers.filter_map do |entry|
          next unless entry.is_a?(Hash)

          key = entry["group_key"] || entry[:group_key]
          answer = entry["answer"] || entry[:answer]
          amendment = entry["amendment"] || entry[:amendment]
          next if key.to_s.blank? || (answer.to_s.blank? && amendment.to_s.blank?)

          { "group_key" => key.to_s, "answer" => answer.to_s.presence, "amendment" => amendment.to_s.presence }.compact
        end
      end

      def answered_group_keys
        normalized_answers.map { |entry| entry.fetch("group_key") }
      end

      def known_group_keys
        @known_group_keys ||= checkpoint.question_groups.map { |group| group["key"] }
      end
    end
  end
end
