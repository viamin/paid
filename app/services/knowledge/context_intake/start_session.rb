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

      private

      def archive_prior_sessions!
        project.context_intake_sessions
               .where(status: %w[completed stale])
               .find_each(&:archive!)
      end

      def create_predefined_responses!(session)
        QuestionnaireSchema.sections.each_with_index do |section, _section_idx|
          section[:questions].each_with_index do |question, q_idx|
            session.context_intake_responses.create!(
              question_key: question[:key],
              question_text: question[:text],
              section: section[:key],
              sequence: q_idx,
              is_follow_up: false,
              skipped: false,
              provenance: "human"
            )
          end
        end
      end
    end
  end
end
