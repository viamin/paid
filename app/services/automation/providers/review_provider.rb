# frozen_string_literal: true

module Automation
  module Providers
    # ReviewProvider defines the capabilities the automation system needs
    # to observe and drive pull-request review flows: inspecting pending
    # and satisfied reviewer state, requesting reviewers, submitting and
    # resolving review threads.
    #
    # A review provider is logically separate from a {RepositoryProvider}
    # because review workflows are often delegated to specialized systems
    # (Reviewable, LGTM apps, in-house bots) that front the source-control
    # host. For providers where reviews live inline with the repository
    # (e.g. GitHub), a single implementation class MAY include both
    # modules.
    #
    # == Contract
    #
    # Implementations MUST:
    #
    # - Report review state as one of the enumerated symbols declared on
    #   {Automation::Providers::Data::Review::STATES}. The raw provider
    #   label MAY be preserved on +raw_state+.
    # - Treat {#fetch_pending_reviewers} and {#fetch_review_requests} as the
    #   authoritative source for "what review is still outstanding". Policy
    #   code uses these methods to distinguish "no review yet" from
    #   "review satisfied".
    # - Ensure write operations are idempotent: re-requesting an already
    #   pending reviewer MUST NOT raise; re-resolving a resolved thread
    #   MUST NOT raise.
    #
    # == Method groups
    #
    # * Read: {#fetch_reviews}, {#fetch_review_threads},
    #   {#fetch_review_requests}, {#fetch_pending_reviewers}
    # * Write: {#request_reviewers}, {#submit_review},
    #   {#resolve_review_thread}
    module ReviewProvider
      class ProviderError < StandardError; end

      # Fetches all completed and in-progress reviews on a pull request.
      #
      # @param repo [String]
      # @param pr_number [Integer]
      # @return [Array<Automation::Providers::Data::Review>]
      def fetch_reviews(repo:, pr_number:)
        raise NotImplementedError, not_implemented_message(__method__)
      end

      # Fetches review threads (line-level discussions) and their
      # resolution state on a pull request.
      #
      # @param repo [String]
      # @param pr_number [Integer]
      # @return [Array<Automation::Providers::Data::ReviewThread>]
      def fetch_review_threads(repo:, pr_number:)
        raise NotImplementedError, not_implemented_message(__method__)
      end

      # Fetches the pending review requests on a pull request.
      #
      # @param repo [String]
      # @param pr_number [Integer]
      # @return [Automation::Providers::Data::ReviewRequest] The pending
      #   users and teams whose review has been requested but not yet
      #   satisfied.
      def fetch_review_requests(repo:, pr_number:)
        raise NotImplementedError, not_implemented_message(__method__)
      end

      # Returns the set of reviewer logins whose review is still pending.
      # A convenience method; providers MAY implement it as a projection
      # over {#fetch_review_requests}.
      #
      # @param repo [String]
      # @param pr_number [Integer]
      # @return [Array<String>] Downcased reviewer logins.
      def fetch_pending_reviewers(repo:, pr_number:)
        raise NotImplementedError, not_implemented_message(__method__)
      end

      # Requests review from users. Idempotent: already-pending reviewers
      # MUST NOT cause the call to fail.
      #
      # @param repo [String]
      # @param pr_number [Integer]
      # @param reviewers [Array<String>] Reviewer logins. Providers MUST
      #   accept downcased logins.
      # @return [Array<String>] The subset of +reviewers+ that the provider
      #   considers newly-requested (i.e. excluding ones that were already
      #   pending).
      def request_reviewers(repo:, pr_number:, reviewers:)
        raise NotImplementedError, not_implemented_message(__method__)
      end

      # Submits a review. Providers that do not distinguish review state
      # (e.g. "approve" vs "request changes") MAY accept only +:comment+
      # but MUST reject the other states loudly.
      #
      # @param repo [String]
      # @param pr_number [Integer]
      # @param body [String] Markdown body.
      # @param event [Symbol] One of +:approve+, +:request_changes+,
      #   +:comment+.
      # @return [Automation::Providers::Data::Review]
      def submit_review(repo:, pr_number:, body:, event:)
        raise NotImplementedError, not_implemented_message(__method__)
      end

      # Marks a review thread as resolved. No-op if already resolved.
      #
      # @param repo [String]
      # @param pr_number [Integer]
      # @param thread_id [String] Provider-local thread identifier, as
      #   returned by {#fetch_review_threads}.
      # @return [void]
      def resolve_review_thread(repo:, pr_number:, thread_id:)
        raise NotImplementedError, not_implemented_message(__method__)
      end

      private

      def not_implemented_message(method_name)
        "#{self.class} must implement ##{method_name}"
      end
    end
  end
end
