# frozen_string_literal: true

module Automation
  module Providers
    # RepositoryProvider defines the capabilities the automation system needs
    # from a source-control provider (GitHub, GitLab, Bitbucket, ...) for pull
    # request orchestration: reading PR state, observing CI checks, and
    # executing the side effects that automation decisions produce (merging,
    # labeling, commenting, marking ready).
    #
    # == Contract
    #
    # Implementations of this module MUST:
    #
    # - Accept the exact keyword arguments declared by each method.
    # - Return values of the documented {Automation::Providers::Data} type, or
    #   +nil+ where explicitly allowed. Providers MUST NOT return raw SDK
    #   objects — the data classes are the stable boundary between automation
    #   policy and provider internals.
    # - Raise a subclass of {ProviderError} for expected transient or
    #   permanent provider failures (authentication, rate limiting, not
    #   found). Unexpected errors may propagate, but callers should be able
    #   to distinguish "provider said no" from "code blew up" via the
    #   provider error hierarchy supplied by the implementation.
    # - Be idempotent for write operations when the underlying API is
    #   idempotent (e.g. merging an already-merged PR succeeds with a
    #   representative {Data::MergeResult}, not an exception).
    #
    # Implementations MAY cache transient state (client handles, pagination
    # cursors) but MUST NOT cache mutable entity state between calls —
    # freshness is the caller's concern.
    #
    # == Usage
    #
    #   provider = Automation::Providers::Resolver.repository_for(project)
    #   pr = provider.fetch_pull_request(repo: "acme/widgets", number: 42)
    #   provider.merge_pull_request(
    #     repo: "acme/widgets", number: 42, method: :squash
    #   ) if pr.mergeable
    #
    # == Method groups
    #
    # * Read: {#fetch_pull_request}, {#list_pull_requests},
    #   {#fetch_pull_request_files}, {#fetch_check_runs}
    # * Write (labels/comments): {#add_labels}, {#remove_label},
    #   {#add_comment}
    # * Write (lifecycle): {#mark_ready_for_review}, {#merge_pull_request}
    module RepositoryProvider
      # Base class for errors raised by provider implementations. Concrete
      # providers may define narrower subclasses (e.g.
      # +GithubRepositoryProvider::NotFoundError+) but SHOULD ensure they
      # inherit from this class so policy code can rescue a single type.
      class ProviderError < StandardError; end

      # Fetches a pull request by its numeric identifier.
      #
      # @param repo [String] Provider-specific repo identifier. For GitHub:
      #   "owner/name". Providers may accept alternate forms (e.g. a numeric
      #   project id) but MUST document the accepted shapes.
      # @param number [Integer] Pull request number (provider-local).
      # @return [Automation::Providers::Data::PullRequest]
      # @raise [ProviderError] When the PR cannot be located or access is
      #   denied.
      def fetch_pull_request(repo:, number:)
        raise NotImplementedError, not_implemented_message(__method__)
      end

      # Lists pull requests for a repository, optionally narrowed by
      # provider-common filters.
      #
      # @param repo [String]
      # @param state [Symbol] One of +:open+, +:closed+, or +:all+. Providers
      #   that do not distinguish these states MAY ignore the parameter but
      #   MUST document the behavior.
      # @param head [String, nil] Optional branch filter ("owner:branch" for
      #   GitHub; provider-specific otherwise).
      # @param base [String, nil] Optional base-branch filter.
      # @return [Array<Automation::Providers::Data::PullRequest>]
      def list_pull_requests(repo:, state: :open, head: nil, base: nil)
        raise NotImplementedError, not_implemented_message(__method__)
      end

      # Returns the file paths modified by a pull request.
      #
      # @param repo [String]
      # @param number [Integer]
      # @return [Array<String>] Changed file paths relative to the repo root.
      def fetch_pull_request_files(repo:, number:)
        raise NotImplementedError, not_implemented_message(__method__)
      end

      # Fetches check runs (CI status) for a git ref. Providers that model CI
      # status separately from "checks" are responsible for normalizing to a
      # unified {Data::CheckRun} representation.
      #
      # @param repo [String]
      # @param ref [String] Branch name, tag, or commit SHA.
      # @return [Array<Automation::Providers::Data::CheckRun>]
      def fetch_check_runs(repo:, ref:)
        raise NotImplementedError, not_implemented_message(__method__)
      end

      # Adds labels to a pull request. Providers that do not support labels
      # natively (e.g. Linear workflow states) SHOULD translate the call into
      # an equivalent status transition and document the mapping.
      #
      # @param repo [String]
      # @param number [Integer]
      # @param labels [Array<String>] Label names to add. Existing labels
      #   MUST NOT be removed.
      # @return [void]
      def add_labels(repo:, number:, labels:)
        raise NotImplementedError, not_implemented_message(__method__)
      end

      # Removes a single label from a pull request. No-op if the label is
      # not currently applied.
      #
      # @param repo [String]
      # @param number [Integer]
      # @param label [String]
      # @return [void]
      def remove_label(repo:, number:, label:)
        raise NotImplementedError, not_implemented_message(__method__)
      end

      # Posts a comment on a pull request's conversation thread.
      #
      # @param repo [String]
      # @param number [Integer]
      # @param body [String] Markdown body.
      # @return [Automation::Providers::Data::Comment] The created comment.
      def add_comment(repo:, number:, body:)
        raise NotImplementedError, not_implemented_message(__method__)
      end

      # Transitions a draft pull request to "ready for review". No-op if the
      # PR is already non-draft.
      #
      # @param repo [String]
      # @param number [Integer]
      # @return [void]
      def mark_ready_for_review(repo:, number:)
        raise NotImplementedError, not_implemented_message(__method__)
      end

      # Merges a pull request.
      #
      # @param repo [String]
      # @param number [Integer]
      # @param method [Symbol] One of +:squash+, +:merge+, +:rebase+.
      #   Providers that do not support a method SHOULD raise
      #   {ProviderError} rather than silently downgrading.
      # @param commit_title [String, nil] Optional merge commit title.
      # @param commit_message [String, nil] Optional merge commit body.
      # @return [Automation::Providers::Data::MergeResult]
      # @raise [ProviderError] When the merge is rejected by the provider
      #   (e.g. merge conflict, protected branch violation).
      def merge_pull_request(repo:, number:, method:, commit_title: nil, commit_message: nil)
        raise NotImplementedError, not_implemented_message(__method__)
      end

      private

      def not_implemented_message(method_name)
        "#{self.class} must implement ##{method_name}"
      end
    end
  end
end
