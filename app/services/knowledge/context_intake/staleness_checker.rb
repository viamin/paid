# frozen_string_literal: true

module Knowledge
  module ContextIntake
    # Checks completed context intake sessions for staleness and marks them
    # as stale when they exceed the configured threshold.
    class StalenessChecker
      attr_reader :project

      def initialize(project: nil)
        @project = project
      end

      def self.call(...)
        new(...).call
      end

      def call
        scope = ContextIntakeSession.completed
        scope = scope.for_project(project) if project

        stale_count = 0
        scope.where("completed_at < ?", ContextIntakeSession::STALENESS_THRESHOLD.ago).find_each do |session|
          session.mark_stale!
          stale_count += 1
        end

        { stale_count: stale_count }
      end
    end
  end
end
