# frozen_string_literal: true

module ClarifyingQuestions
  # Clears an issue's "needs input" marker once its clarifying questions have
  # been answered: removes the needs-input label on GitHub and resets
  # paid_state so the "Answer Questions" button disappears and the issue
  # re-enters the pipeline. Also accepts a `manual_review` issue whose
  # parked state preserved parseable clarifying questions
  # (ISSUE-ENHANCEMENT-011) — answering those from the inbox is itself the
  # manual review the state asks for, so it clears the same way (or, when a
  # create_feature run is paused on the issue, resumes that run under the
  # same manual_review-clearing state flip).
  #
  # Idempotent (a no-op unless the issue is currently awaiting input) and
  # best-effort: a GitHub failure is logged but still updates local state, and
  # the next sync reconciles the label via
  # FetchIssuesActivity#detect_needs_input_label_removals. The label removed is
  # the enhancement needs-input label (what EnhanceIssueActivity adds and what
  # Issue#needs_input? checks), not the no-output label.
  class ClearNeedsInput
    def self.call(...)
      new(...).call
    end

    def initialize(project:, issue:)
      @project = project
      @issue = issue
    end

    def call
      return unless issue.needs_input? || issue_paid_state_needs_input? || issue_paid_state_manual_review?

      label = project.enhance_issue_needs_input_label_name
      remove_label(label) if issue.has_label?(label)

      # Check if this issue is associated with a paused create_feature run.
      # It will re-assess the original brief with the admitted answer comment
      # when it resumes, rather than mapping answers from fixed question text.
      create_feature_run = paused_create_feature_run_for(issue)
      if create_feature_run
        assemble_and_resume_create_feature!(create_feature_run, issue, label)
        return
      end

      # Reset the enhancement round counter on human signal — the operator has
      # just answered clarifying questions, which is the meaningful human input
      # that should restart the cap budget so a later regression doesn't inherit
      # an exhausted automatic-retry budget (#3842).
      attrs = {
        paid_state: "new",
        labels: Array(issue.labels) - [ label ],
        needs_input_questions: nil
      }
      attrs[:enhance_issue_rounds] = 0 if issue.respond_to?(:enhance_issue_rounds) && issue.enhance_issue_rounds.to_i.positive?
      # @spec OPERATOR-INBOX-007
      issue.update!(attrs)
    end

    private

    attr_reader :project, :issue

    def issue_paid_state_needs_input?
      issue.respond_to?(:paid_state) && issue.paid_state == "needs_input"
    end

    def issue_paid_state_manual_review?
      issue.respond_to?(:paid_state) && issue.paid_state == "manual_review"
    end

    def remove_label(label)
      project.client&.remove_label_from_issue(project.full_name, issue.github_number, label)
    rescue GithubClient::Error => e
      Rails.logger.warn(
        message: "clarifying_questions.remove_needs_input_label_failed",
        issue_number: issue.github_number,
        label: label,
        error: e.message
      )
    end

    # Returns the paused create_feature run associated with this issue, if any.
    def paused_create_feature_run_for(issue)
      return unless issue.respond_to?(:agent_runs)

      issue.agent_runs.paused.find_by(goal: "create_feature")
    end

    # Resumes a create_feature run after a human answer. The resumed activity
    # re-runs semantic feature-brief assessment, so adaptive questions do not
    # need a wording- or position-dependent answer mapping here.
    # @spec FEATURE-CREATION-002
    def assemble_and_resume_create_feature!(agent_run, issue, label)
      agent_run.clear_feature_clarification_round!
      # For a needs_input source, paid_state stays as-is (the run is
      # resuming, not being reset to "new"), so the paid_state-change
      # callback on Issue does NOT fire — the issue is no longer waiting on
      # a human but the column would otherwise keep the stale timestamp.
      # Clear it explicitly so the inbox does not surface this issue as
      # still awaiting input.
      attrs = {
        needs_input_questions: nil,
        needs_input_since: nil,
        labels: Array(issue.labels) - [ label ]
      }
      # A manual_review source must clear in this same action: the resume
      # path never touches paid_state, so without this flip the issue would
      # linger in the manual-review lane (which auto-pick skips) until the
      # resumed run completes. "in_progress" is the same queue-time state
      # flip an operator-triggered enhancement run applies
      # (AgentRunsController#resume_issue_from_manual_review), and the
      # human signal of answering resets the round budget like every other
      # answer path.
      # @spec ISSUE-ENHANCEMENT-011 @spec ISSUE-ENHANCEMENT-014
      if issue_paid_state_manual_review?
        attrs[:paid_state] = "in_progress"
        attrs[:enhance_issue_rounds] = 0 if issue.respond_to?(:enhance_issue_rounds) && issue.enhance_issue_rounds.to_i.positive?
      end
      # @spec INBOX-FOUNDATION-002
      issue.update!(attrs)

      agent_run.resume!(decision_point: "create_feature.needs_input_answered")
      ProcessRunQueueJob.perform_later

      Rails.logger.info(
        message: "agent_execution.create_feature_needs_input_answered",
        agent_run_id: agent_run.id,
        issue_id: issue.id
      )
    end
  end
end
