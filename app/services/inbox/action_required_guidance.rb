# frozen_string_literal: true

module Inbox
  # Identifies notifications that have a first-class in-product workflow.
  # Notification prose remains the fallback for every other Action Required
  # item; only an explicit producer marker can opt into typed guidance.
  # @spec OPERATOR-INBOX-002L
  class ActionRequiredGuidance
    FACET_CONFIDENCE_WORKFLOW = "facet_confidence_closeout_evaluation"
    FACET_CONFIDENCE_SOURCES = %w[
      facet_confidence_closeout_evaluation
      facet_confidence_reference_judgments
    ].freeze

    def self.call(notification)
      new(notification).call
    end

    def initialize(notification)
      @notification = notification
    end

    def call
      return unless facet_confidence?

      {
        workflow: FACET_CONFIDENCE_WORKFLOW,
        title: "Evaluation needed to complete this closeout",
        explanation: "This closeout is waiting for a human to review each frozen test case, record one judgment per case, and freeze the completed set."
      }
    end

    private

    attr_reader :notification

    def facet_confidence?
      notification.metadata["inbox_workflow"] == FACET_CONFIDENCE_WORKFLOW ||
        FACET_CONFIDENCE_SOURCES.include?(notification.source)
    end
  end
end
