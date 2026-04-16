# frozen_string_literal: true

module Automation
  module Providers
    module Github
      # Shared behavior for the GitHub-backed automation adapters.
      #
      # All three capability adapters (repository, review, work item) front
      # the same underlying {::GithubClient}. BaseAdapter resolves the client
      # from the project, centralizes error translation into the provider
      # error hierarchy expected by automation policy, and provides the small
      # helpers the adapters share (login normalization, timestamp parsing,
      # etc.).
      #
      # Adapters MUST wrap outbound GitHub calls in {#with_errors} so that
      # policy code rescues a single +ProviderError+ family regardless of
      # which adapter raised.
      class BaseAdapter
        # Error class the concrete adapter raises on provider failure.
        # Subclasses override to point at the capability-specific hierarchy
        # (RepositoryProvider::ProviderError, etc.) so policy code can
        # rescue narrowly without losing access to the unified family.
        PROVIDER_ERROR = Class.new(StandardError)

        attr_reader :project

        # @param project [Project, #github_token] The Paid project whose
        #   GitHub credentials back this adapter. Tests may pass any object
        #   responding to +#github_token+ (or +#client+ directly via the
        #   +client:+ keyword) to avoid loading a real project.
        # @param client [::GithubClient, nil] Optional pre-built client for
        #   tests. When omitted, the client is lazily derived from
        #   +project.github_token.client+.
        def initialize(project, client: nil)
          @project = project
          @client = client
        end

        # Exposes the underlying GitHub client to subclasses and specs.
        #
        # @return [::GithubClient]
        def client
          @client ||= resolve_client
        end

        private

        def resolve_client
          token = project.respond_to?(:github_token) ? project.github_token : nil
          raise provider_error_class, "Project #{project_identifier} has no GitHub token" if token.nil?

          token.client
        end

        def project_identifier
          project.respond_to?(:full_name) ? project.full_name : project.inspect
        end

        # Wraps a GitHub API call, translating {::GithubClient} error classes
        # into this adapter's ProviderError. Unknown errors propagate so
        # that genuine bugs do not masquerade as provider failures.
        def with_errors
          yield
        rescue ::GithubClient::Error => e
          raise provider_error_class, e.message
        end

        # Concrete adapters override to return the capability-specific
        # ProviderError class declared by the interface module.
        def provider_error_class
          self.class::PROVIDER_ERROR
        end

        def normalize_login(value)
          value&.to_s&.downcase.presence
        end

        def parse_time(value)
          case value
          when Time, ActiveSupport::TimeWithZone then value
          when String then Time.parse(value)
          end
        rescue ArgumentError
          nil
        end

        def extract_labels(source)
          Array(source).map { |label| label.respond_to?(:name) ? label.name : label.to_s }
        end

        # Accept either a Sawyer::Resource (Octokit's default) or a plain Hash
        # with symbol/string keys so adapters stay usable in unit tests that
        # stub the client with hashes.
        def read_field(source, key)
          return nil if source.nil?

          if source.respond_to?(key)
            source.public_send(key)
          elsif source.respond_to?(:[])
            source[key] || source[key.to_s]
          end
        end

        def read_sub_field(source, *keys)
          keys.reduce(source) { |acc, key| acc && read_field(acc, key) }
        end
      end
    end
  end
end
