# frozen_string_literal: true

module Automation
  module Strategies
    class AutoReview
      # Outcome reports where a single review method stands in the auto-review
      # lifecycle. {Strategies::AutoReview} aggregates per-method outcomes
      # from {Automation::ReviewMethods} plugins into the final
      # {Automation::Result}.
      #
      # == Outcome states
      #
      # * +:pending+            — the method expects further activity before
      #   the PR is ready (e.g. review not yet submitted, reviewer not yet
      #   approved, CI action not yet run).
      # * +:satisfied+          — the method has completed successfully for
      #   the current PR head (e.g. clean review, approval on file,
      #   action_name check succeeded).
      # * +:retryable_failure+  — the method failed but the configured retry
      #   budget permits another attempt (paid_agent only, today).
      # * +:exhausted_retries+  — the method failed and the retry budget has
      #   been spent. Callers SHOULD escalate to a human.
      # * +:not_applicable+     — the method is disabled or does not apply
      #   to the current phase (e.g. draft copilot review when the review
      #   toggle is off).
      #
      # == Blocking semantics
      #
      # A +pending+ outcome may be either +blocking+ (acts as a hard gate on
      # PR progress — e.g. +paid_agent+ when it is the sole enabled method,
      # or +manual+/+ci_action+ when +wait_for_reviews+ is on) or
      # +non-blocking sidecar+ (surfaces a review action alongside other
      # follow-up work without stopping the PR — e.g. a copilot review
      # requested while auto-continue proceeds). Every factory accepts a
      # +blocking:+ kwarg so callers can declare the policy explicitly.
      class Outcome < ::Data.define(:method, :state, :blocking, :message, :metadata)
        STATES = %i[pending satisfied retryable_failure exhausted_retries not_applicable].freeze

        EMPTY_METADATA = {}.freeze

        class << self
          def pending(method:, blocking: false, message: nil, metadata: EMPTY_METADATA)
            build(method:, state: :pending, blocking:, message:, metadata:)
          end

          def satisfied(method:, message: nil, metadata: EMPTY_METADATA)
            build(method:, state: :satisfied, blocking: false, message:, metadata:)
          end

          def retryable_failure(method:, blocking: true, message: nil, metadata: EMPTY_METADATA)
            build(method:, state: :retryable_failure, blocking:, message:, metadata:)
          end

          def exhausted_retries(method:, blocking: true, message: nil, metadata: EMPTY_METADATA)
            build(method:, state: :exhausted_retries, blocking:, message:, metadata:)
          end

          def not_applicable(method:, message: nil)
            build(method:, state: :not_applicable, blocking: false, message:, metadata: EMPTY_METADATA)
          end

          private

          def build(method:, state:, blocking:, message:, metadata:)
            unless STATES.include?(state)
              raise ArgumentError, "Unknown outcome state: #{state.inspect}"
            end

            new(
              method: method.to_sym,
              state: state,
              blocking: blocking == true,
              message: message,
              metadata: (metadata || EMPTY_METADATA).freeze
            )
          end
        end

        STATES.each do |s|
          define_method(:"#{s}?") { state == s }
        end

        def blocking? = blocking == true
        def sidecar? = !blocking?

        def to_h
          {
            method: method,
            state: state,
            blocking: blocking,
            message: message,
            metadata: metadata
          }
        end
      end
    end
  end
end
