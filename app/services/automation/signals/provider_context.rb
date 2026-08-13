# frozen_string_literal: true

module Automation
  module Signals
    # Bundles the provider adapters a signal collector needs for a single
    # project, all sharing one credential-aware client.
    #
    # When +client+ is supplied it is forwarded to the provider resolver so
    # every adapter reuses that client instead of each re-deriving one from
    # the project. This keeps a single client across a scan cycle (matching
    # the client the orchestration layer already resolved) and lets callers
    # that hold a specific client — including unit tests — drive the
    # providers through it.
    class ProviderContext
      attr_reader :project, :repository_provider, :review_provider, :work_item_provider

      def self.for(project, client: nil)
        new(
          project: project,
          repository_provider: Automation::Providers::Resolver.repository_for(project, client: client),
          review_provider: Automation::Providers::Resolver.review_for(project, client: client),
          work_item_provider: Automation::Providers::Resolver.work_item_for(project, client: client)
        )
      end

      def initialize(project:, repository_provider:, review_provider:, work_item_provider:)
        @project = project
        @repository_provider = repository_provider
        @review_provider = review_provider
        @work_item_provider = work_item_provider
      end

      def repo
        project.full_name
      end
    end
  end
end
