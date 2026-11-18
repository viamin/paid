# frozen_string_literal: true

module ProjectDelegation
  class IntentCheckpoint
    # @spec PROJECT-DELEGATION-002
    class Plan
      Result = Data.define(:checkpoint, :questions)

      def self.call(...) = new(...).call

      def initialize(feature_intent:, questions:, recommendation:, alternatives:, consequences:, affected_scope:, evidence: [],
        design_revision:, acceptance_revision:)
        @feature_intent = feature_intent
        @questions = Array(questions)
        @attributes = {
          recommendation:, alternatives: Array(alternatives), consequences: Array(consequences),
          affected_scope: affected_scope.to_h, evidence: Array(evidence),
          proposed_design_revision: design_revision, proposed_acceptance_revision: acceptance_revision
        }
      end

      def call
        raise ArgumentError, "At least one material question is required" if questions.empty?
        raise ArgumentError, "Checkpoint revisions must be present" if attributes[:proposed_design_revision].blank? ||
          attributes[:proposed_acceptance_revision].blank?

        ActiveRecord::Base.transaction do
          checkpoint = feature_intent.project_delegation_intent_checkpoints.create!(attributes)
          checkpoint.questions = questions
          Result.new(checkpoint:, questions: checkpoint.questions)
        end
      end

      private

      attr_reader :feature_intent, :questions, :attributes
    end
  end
end
