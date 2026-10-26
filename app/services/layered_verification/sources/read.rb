# frozen_string_literal: true

module LayeredVerification
  module Sources
    # Reads one source reference at a pinned revision through the project's
    # GitHub credential. A read that fails is reported as a missing source
    # with its reason; it is never presented as empty content.
    #
    # @spec LAYERED-VERIFY-021 @spec LAYERED-VERIFY-024
    class Read
      Result = Data.define(:path, :content, :error) do
        def found? = error.nil? && content.present?
      end

      def self.call(...)
        new(...).call
      end

      def initialize(project:, revision:, client: nil)
        @project = project
        @revision = revision
        @client = client
      end

      def call(path)
        github = client || project.client
        return Result.new(path:, content: nil, error: "no GitHub credential is configured for this project") unless github

        content = github.file_content(project.repo, path:, ref: revision)
        Result.new(path:, content:, error: content.present? ? nil : "the source is empty at this revision")
      rescue GithubClient::NotFoundError
        Result.new(path:, content: nil, error: "the source does not exist at the pinned revision")
      rescue GithubClient::Error => e
        Result.new(path:, content: nil, error: "the source could not be read: #{e.class.name.demodulize}")
      end

      private

      attr_reader :client, :project, :revision
    end
  end
end
