# frozen_string_literal: true

module Knowledge
  module ContextIntake
    # Creates a new context intake session and pre-populates response records
    # from the questionnaire schema. Archives any prior completed sessions.
    class StartSession
      attr_reader :project, :user

      def initialize(project:, user:)
        @project = project
        @user = user
      end

      def self.call(...)
        new(...).call
      end

      def call
        ActiveRecord::Base.transaction do
          archive_prior_sessions!

          session = project.context_intake_sessions.create!(
            started_by: user,
            status: "in_progress",
            schema_version: "1.0",
            current_step: 0,
            metadata: {}
          )

          create_predefined_responses!(session)

          session
        end
      end

      private

      def archive_prior_sessions!
        project.context_intake_sessions
               .where(status: %w[completed stale])
               .find_each(&:archive!)
      end

      def create_predefined_responses!(session)
        AppendQuestions.call(
          session: session,
          questions: QuestionnaireSchema.ordered_questions(project: project).select { |question| question[:round] == 1 }
        )
      end
    end
  end
end
