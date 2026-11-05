# frozen_string_literal: true

module Inbox
  # A small, deterministic opening summary for every human-actionable Inbox
  # item. It intentionally only reads the entry supplied by the queue: detail
  # rendering must not make a remote request or ask an LLM to infer a next step.
  # @spec OPERATOR-INBOX-026
  class DecisionBrief
    Brief = Data.define(
      :project, :work_item, :goal, :changed, :decision, :recommendation,
      :rationale, :waiting_on, :after_action, :primary_action,
      :evidence_status, :question
    ) do
      def focused_question
        question
      end

      def list_label
        [ "Project: #{project}", "Work: #{work_item}", "Action: #{decision}", "Impact: #{waiting_on}" ].join(" · ")
      end

      def to_h
        {
          project:, work_item:, goal:, changed:, decision:, recommendation:,
          rationale:, waiting_on:, after_action:, primary_action:,
          evidence_status:, focused_question:
        }
      end
    end

    def self.call(...) = new(...).call

    def initialize(entry:)
      @entry = entry
    end

    def call
      Brief.new(
        project: entry.project.full_name,
        work_item: title,
        goal: title,
        changed: summary,
        decision: profile.fetch(:decision),
        recommendation: profile.fetch(:recommendation),
        rationale: summary,
        waiting_on: profile.fetch(:waiting_on),
        after_action: profile.fetch(:after_action),
        primary_action: profile.fetch(:primary_action),
        evidence_status: profile.fetch(:evidence_status),
        question: profile.fetch(:question)
      )
    end

    private

    attr_reader :entry

    def title
      entry.title.presence || "Inbox work"
    end

    def summary
      entry.summary.to_s.squish.presence || "Paid is waiting for this action."
    end

    def profile
      @profile ||= PROFILES.fetch(entry.kind, DEFAULT_PROFILE).call(entry)
    end

    DEFAULT_PROFILE = lambda { |_entry|
      supported_profile("Review this work", "Review the current work, then choose the next step.", "Review work")
    }.freeze

    PROFILES = {
      Queue::CLARIFYING_QUESTIONS_KIND => lambda { |entry|
        {
          decision: "Answer one product question",
          recommendation: nil,
          waiting_on: "Paid cannot continue until the answer is recorded.",
          after_action: "Paid can continue with the clarified goal.",
          primary_action: "Answer the question",
          evidence_status: "unknown",
          question: entry.questions.first.presence || "What outcome should this work produce?"
        }
      },
      Queue::MANUAL_REVIEW_KIND => lambda { |_entry|
        supported_profile("Review the stopped work", "Review the stop reason, then resume analysis if it still applies.", "Resume analysis")
      },
      Queue::ACTION_REQUIRED_KIND => lambda { |entry|
        supported_profile("Fix a blocking configuration problem", entry.summary.presence || "Complete the required remediation.", "Fix the blocking problem")
      },
      Queue::PARTIAL_CLOSEOUT_KIND => lambda { |entry|
        partial_closeout_profile(entry)
      },
      Queue::MERGE_APPROVAL_KIND => lambda { |_entry|
        merge_approval_profile(_entry)
      },
      Queue::PLAN_REVIEW_KIND => lambda { |_entry|
        supported_profile("Review the proposed plan", "Review the proposed work before Paid starts it.", "Review the plan")
      }
    }.freeze

    def self.supported_profile(decision, recommendation, primary_action)
      {
        decision:, recommendation:, waiting_on: "Related work is waiting for this decision.",
        after_action: "Paid will reevaluate the next relevant item.", primary_action:,
        evidence_status: "current", question: nil
      }
    end

    def self.partial_closeout_profile(entry)
      return unsupported_closeout_profile unless entry.closeout_status

      supported_profile("Resolve the incomplete closeout", entry.closeout_status.reason, "Review closeout evidence")
    end

    def self.merge_approval_profile(entry)
      guidance = entry.guidance || {}
      profile = supported_profile(
        "Review the pull request",
        guidance[:instruction].presence || "Review the current pull request and make the required GitHub decision.",
        "Review on GitHub"
      )
      return profile unless guidance[:stale_approval]

      profile.merge(evidence_status: "stale")
    end

    def self.unsupported_closeout_profile
      {
        decision: "Resolve the incomplete closeout", recommendation: nil,
        waiting_on: "Paid cannot safely continue without recorded closeout evidence.",
        after_action: "Paid can reassess the remaining acceptance work.",
        primary_action: "Review closeout evidence", evidence_status: "unavailable",
        question: "Which acceptance result is still missing?"
      }
    end
  end
end
