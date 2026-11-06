# frozen_string_literal: true

module ProjectDelegation
  module IntentCheckpoint
    # Single write boundary for a human settlement of an intent checkpoint.
    # The settlement records the decision (settled, rejected, or amended) and
    # per-group answers, bound immutably to the checkpoint's design and
    # acceptance revision; a later settlement appends history rather than
    # rewriting the earlier record.
    # @spec PROJECT-DELEGATION-002
    class Settle
      class Error < StandardError; end
      class PermissionDenied < Error; end
      class InvalidState < Error; end
      class InvalidDecision < Error; end
      class InvalidAnswers < Error; end

      def self.call(...)
        new(...).call
      end

      def initialize(checkpoint:, user:, decision:, answers:)
        @checkpoint = checkpoint
        @user = user
        @decision = decision.to_s
        @answers = answers
      end

      def call
        ensure_permission!
        ensure_state!
        ensure_decision!
        ensure_answers!

        @checkpoint.transaction do
          settlement = @checkpoint.settlements.create!(
            account: @checkpoint.account, project: @checkpoint.project, settled_by: @user,
            decision: @decision, answers: normalized_answers,
            design_revision: @checkpoint.design_revision,
            acceptance_revision: @checkpoint.acceptance_revision
          )
          Audit::RecordEvent.call(
            action: "delegation_checkpoint.settled",
            actor: @user,
            subject: settlement,
            metadata: {
              "decision" => @decision,
              "design_revision" => @checkpoint.design_revision,
              "acceptance_revision" => @checkpoint.acceptance_revision,
              "group_keys" => settlement.answers.map { |answer| answer["key"] }
            }
          )
          settlement
        end
      end

      private

      attr_reader :checkpoint, :user, :decision, :answers

      def ensure_permission!
        return if ProjectPolicy.new(user, checkpoint.project).settle_intent_checkpoint?

        raise PermissionDenied, "You do not have permission to settle intent for this project."
      end

      def ensure_state!
        return if checkpoint.status == "open"

        raise InvalidState, "Only an open checkpoint can be settled."
      end

      def ensure_decision!
        return if decision.in?(ProjectDelegation::Settlement::DECISIONS)

        raise InvalidDecision, "A settlement must settle, reject, or amend the checkpoint."
      end

      def ensure_answers!
        raise InvalidAnswers, "Answers must be a list." unless answers.is_a?(Array)

        normalized = normalized_answers
        keys = normalized.map { |answer| answer["key"] }
        duplicates = keys.tally.select { |_, count| count > 1 }.keys
        unless duplicates.empty?
          raise InvalidAnswers, "Answers must be unique per group: #{duplicates.join(', ')}."
        end

        return unless decision == "settled"

        missing = asked_keys - keys
        return if missing.empty?

        raise InvalidAnswers, "Every group must be answered: #{missing.join(', ')}."
      end

      def normalized_answers
        answers.map { |answer| normalize_answer(answer) }
      end

      def normalize_answer(answer)
        raise InvalidAnswers, "Each answer must be an object with key and choice." unless answer.is_a?(Hash)

        key = answer["key"] || answer[:key]
        choice = answer["choice"] || answer[:choice]
        raise InvalidAnswers, "#{key.presence || '<unnamed>'} was not asked." unless key.in?(asked_keys)
        raise InvalidAnswers, "#{key} needs a choice." unless choice.is_a?(String) && choice.strip.present?

        normalized = { "key" => key, "choice" => choice.strip }
        note = answer["note"] || answer[:note]
        normalized["note"] = note.strip if note.is_a?(String) && note.strip.present?
        normalized
      end

      def asked_keys
        @asked_keys ||= checkpoint.group_keys
      end
    end
  end
end
