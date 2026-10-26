# frozen_string_literal: true

module LayeredVerification
  module Projects
    # Resolves the revision the project currently sits at: the head of its
    # default branch. Purely structural — it reads the repository, it never
    # judges anything.
    #
    # @spec LAYERED-VERIFY-018
    class CurrentRevision
      def self.call(...)
        new(...).call
      end

      def initialize(project:, client: nil)
        @project = project
        @client = client
      end

      def call
        github = client || project.client
        return unless github

        github.ref(project.repo, "heads/#{project.default_branch}").object.sha
      rescue GithubClient::Error => e
        Rails.logger.warn(
          message: "layered_verification.current_revision_failed",
          project_id: project.id,
          error_class: e.class.name,
          error: e.message
        )
        nil
      end

      private

      attr_reader :client, :project
    end
  end
end
