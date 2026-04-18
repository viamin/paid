# frozen_string_literal: true

module Automation
  module ReviewMethods
    # Contract implemented by every review method plugin.
    #
    # Each plugin encapsulates the per-method auto-review policy: given the
    # method's configuration and the current scan signals, it reports an
    # {Automation::Strategies::AutoReview::Outcome} and (optionally) the
    # concrete {Automation::Decision} that should be emitted to advance
    # that method's state.
    #
    # Plugins are intentionally stateless — a fresh instance is constructed
    # per evaluation with the current config and signals. Subclasses
    # override {#evaluate}, {#decision}, and {#kind}.
    #
    # == Plugin taxonomy ({#kind})
    #
    # * +:bot+    — automated reviewer backed by a GitHub bot account
    #   (copilot). Requests review via GraphQL; produces inline threads.
    # * +:agent+  — Paid's own review agent (paid_agent). Runs in a
    #   Temporal workflow; produces a review body.
    # * +:comment_bot+ — a bot triggered by @-mention comment (codex). Posts
    #   a body-only review.
    # * +:human+  — explicit human reviewer (manual). Gated on approval.
    # * +:ci+     — GitHub Action (ci_action). Gated on check-run success.
    class Base
      # @param method [Automation::Configuration::ReviewMethod]
      # @param config [Automation::Configuration::AutoReview]
      # @param signals [Automation::Strategies::AutoReview::Signals]
      def initialize(method:, config:, signals:)
        @method = method
        @config = config
        @signals = signals
      end

      # @return [Symbol] the canonical method name (:paid_agent, :copilot, ...)
      def name
        method.name
      end

      # @return [Symbol] kind of provider (see class-level docs).
      def kind
        raise NotImplementedError, "#{self.class} must implement #kind"
      end

      # Whether an unsatisfied outcome from this method should block PR
      # progress by default. Individual {#evaluate} implementations may
      # override on a case-by-case basis via the +blocking:+ kwarg on
      # Outcome factories.
      def blocking_by_default?
        false
      end

      # @return [Automation::Strategies::AutoReview::Outcome]
      def evaluate
        raise NotImplementedError, "#{self.class} must implement #evaluate"
      end

      # Concrete Decision this method wants emitted alongside its Outcome,
      # or +nil+ when no provider-side action is needed.
      #
      # @return [Automation::Decision, nil]
      def decision
        nil
      end

      protected

      attr_reader :method, :config, :signals

      def outcome_pending(blocking: blocking_by_default?, message: nil, metadata: Automation::Strategies::AutoReview::Outcome::EMPTY_METADATA)
        Automation::Strategies::AutoReview::Outcome.pending(method: name, blocking:, message:, metadata:)
      end

      def outcome_satisfied(message: nil, metadata: Automation::Strategies::AutoReview::Outcome::EMPTY_METADATA)
        Automation::Strategies::AutoReview::Outcome.satisfied(method: name, message:, metadata:)
      end

      def outcome_retryable_failure(blocking: true, message: nil, metadata: Automation::Strategies::AutoReview::Outcome::EMPTY_METADATA)
        Automation::Strategies::AutoReview::Outcome.retryable_failure(method: name, blocking:, message:, metadata:)
      end

      def outcome_exhausted_retries(blocking: true, message: nil, metadata: Automation::Strategies::AutoReview::Outcome::EMPTY_METADATA)
        Automation::Strategies::AutoReview::Outcome.exhausted_retries(method: name, blocking:, message:, metadata:)
      end

      def outcome_not_applicable(message: nil)
        Automation::Strategies::AutoReview::Outcome.not_applicable(method: name, message:)
      end
    end
  end
end
