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

        resync_knowledge_artifact!
        change_intent
      end

      private

      # The indexed knowledge artifact snapshots the record's status in both
      # content and metadata; re-sync after the promotion commits so the
      # search index and opted-in context bundles reflect `Status: promoted`
      # instead of the stale `Status: observation` captured at run time. The
      # change_intent draft is the user's primary deliverable, so log a sync
      # failure rather than failing the promotion — the artifact can be
      # re-synced later by re-running Promote or SyncKnowledgeArtifact
      # directly. SyncKnowledgeArtifact already marks its collector_run
      # failed and re-raises; we just downgrade that here.
      def resync_knowledge_artifact!
        session_summary.reload
        Knowledge::SessionSummaries::SyncKnowledgeArtifact.call(session_summary: session_summary)
      rescue StandardError => e
        Rails.logger.error(
          message: "knowledge.session_summary_promote_resync_failed",
          agent_run_session_summary_id: session_summary.id,
          change_intent_id: session_summary.change_intent_id,
          error_class: e.class.name,
          error: e.message
        )
      end

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
