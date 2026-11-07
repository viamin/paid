# frozen_string_literal: true

module ProjectDelegation
  module IntentCheckpoint
    # Persists the reviewable intent checkpoint for a work item and surfaces
    # it as one blocking Inbox request. Idempotent for the current plan and
    # revisions; a changed question set or revision supersedes the pending
    # checkpoint (and its Inbox request is refreshed) so the Inbox always
    # shows the material questions that currently gate delegated work.
    # @spec PROJECT-DELEGATION-002
    class Open
      NOTIFICATION_SOURCE = "project_delegation_intent_checkpoint"

      def self.call(...)
        new(...).call
      end

      def initialize(project:, issue:, actor: nil)
        @project = project
        @issue = issue
        @actor = actor
      end

      def call
        return nil unless plan.material?

        revisions = Revisions.for(issue)
        checkpoint = find_or_create_checkpoint(revisions)
        publish_request(checkpoint)
        checkpoint
      end

      private

      attr_reader :project, :issue, :actor

      def plan
        @plan ||= Plan.call(project: project, issue: issue)
      end

      def find_or_create_checkpoint(revisions)
        existing = issue.delegation_intent_checkpoints.pending.first
        return existing if existing && current?(existing, revisions)

        ActiveRecord::Base.transaction do
          existing&.supersede!
          create_checkpoint(revisions)
        end
      end

      def current?(checkpoint, revisions)
        checkpoint.question_set_digest == plan.question_set_digest &&
          checkpoint.design_revision == revisions.fetch("design_revision") &&
          checkpoint.acceptance_revision == revisions.fetch("acceptance_revision")
      end

      def create_checkpoint(revisions)
        DelegationIntentCheckpoint.create!(
          account: project.account,
          project: project,
          issue: issue,
          feature_intent: plan.feature_intent,
          status: "pending",
          design_revision: revisions.fetch("design_revision"),
          acceptance_revision: revisions.fetch("acceptance_revision"),
          evidence_revision: revisions.fetch("evidence_revision"),
          question_groups: plan.groups.map(&:to_h),
          question_set_digest: plan.question_set_digest,
          created_by: actor
        )
      rescue ActiveRecord::RecordNotUnique
        issue.delegation_intent_checkpoints.pending.first
      end

      def publish_request(checkpoint)
        Notifications::Publish.call(
          account: project.account,
          subject: issue,
          source: NOTIFICATION_SOURCE,
          severity: :error,
          blocking: true,
          nav_section: "projects",
          title: "Material intent questions need one settlement",
          description: description(checkpoint),
          metadata: {
            "checkpoint_id" => checkpoint.id,
            "design_revision" => checkpoint.design_revision,
            "acceptance_revision" => checkpoint.acceptance_revision,
            "question_set_digest" => checkpoint.question_set_digest,
            "groups" => group_summaries(checkpoint)
          }
        )
      end

      def description(checkpoint)
        groups = checkpoint.question_groups
        "Settle #{groups.size} grouped material question#{'s' if groups.size != 1} " \
          "before delegated work continues (bound to design revision #{checkpoint.design_revision[0, 12]} " \
          "and acceptance revision #{checkpoint.acceptance_revision[0, 12]})."
      end

      def group_summaries(checkpoint)
        checkpoint.question_groups.map do |group|
          {
            "key" => group["key"],
            "question" => group["question"],
            "recommendation" => group["recommendation"],
            "alternatives" => group["alternatives"],
            "consequences" => group["consequences"],
            "affected_scope" => group["affected_scope"],
            "evidence" => group["evidence"]
          }
        end
      end
    end
  end
end
