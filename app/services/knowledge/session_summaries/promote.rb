# frozen_string_literal: true

module Knowledge
  module SessionSummaries
    # Promotes a session-summary observation into a draft Change Intent
    # Record, reusing the existing Change Intent draft/approve/discard
    # lifecycle (Projects::ChangeIntentsController) rather than building a
    # second review surface. The summary stays linked to the created draft;
    # it only counts as durable project intent once a human approves it
    # through that existing flow.
    #
    # @spec SESSION-SUMMARY-004
    class Promote
      attr_reader :session_summary, :user

      def initialize(session_summary:, user:)
        @session_summary = session_summary
        @user = user
      end

      def self.call(...)
        new(...).call
      end

      def call
        change_intent = nil

        ActiveRecord::Base.transaction do
          change_intent = ChangeIntent.create!(change_intent_attributes)
          session_summary.promote!(change_intent: change_intent, user: user)
        end

        change_intent
      end

      private

      def change_intent_attributes
        {
          project: session_summary.project,
          issue: session_summary.issue,
          title: "Session summary: agent run ##{session_summary.agent_run_id}".truncate(500),
          intent: session_summary.summary,
          behavior: bullet_text(session_summary.follow_ups),
          constraints: bullet_text(session_summary.assumptions),
          decisions_made: decisions_made_text,
          status: "draft"
        }
      end

      def decisions_made_text
        [
          bullet_section("Decisions", session_summary.decisions),
          bullet_section("Failed approaches", session_summary.failures),
          bullet_section("Learnings", session_summary.learnings)
        ].compact.join("\n\n").presence
      end

      def bullet_section(heading, items)
        text = bullet_text(items)
        return nil if text.nil?

        "#{heading}:\n#{text}"
      end

      def bullet_text(items)
        Array(items).map { |item| "- #{item}" }.join("\n").presence
      end
    end
  end
end
