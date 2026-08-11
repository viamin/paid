# frozen_string_literal: true

module ClarifyingQuestions
  # Clears an issue's "needs input" marker once its clarifying questions have
  # been answered: removes the needs-input label on GitHub and resets
  # paid_state so the "Answer Questions" button disappears and the issue
  # re-enters the pipeline.
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
      return unless issue.needs_input?

      label = project.enhance_issue_needs_input_label_name
      remove_label(label)

      # Check if this issue is associated with a paused create_feature run.
      # If so, assemble the feature brief from the answers and resume the run
      # instead of resetting to "new" (RDR-053 needs-input Q&A flow).
      create_feature_run = paused_create_feature_run_for(issue)
      if create_feature_run
        assemble_and_resume_create_feature!(create_feature_run, issue, label)
        return
      end

      issue.update!(paid_state: "new", labels: Array(issue.labels) - [ label ], needs_input_questions: nil)
    end

    private

    attr_reader :project, :issue

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

    # Assembles a feature brief from the clarifying question answers and
    # resumes the paused create_feature run so the agent can proceed with
    # a complete brief (RDR-053).
    def assemble_and_resume_create_feature!(agent_run, issue, label)
      brief = assemble_feature_brief_from_answers(issue)
      existing = agent_run.external_metadata.is_a?(Hash) ? agent_run.external_metadata : {}
      agent_run.update!(external_metadata: existing.merge("feature_brief" => brief))
      issue.update!(needs_input_questions: nil, labels: Array(issue.labels) - [ label ])

      agent_run.resume!(decision_point: "create_feature.needs_input_answered")
      ProcessRunQueueJob.perform_later

      Rails.logger.info(
        message: "agent_execution.create_feature_needs_input_answered",
        agent_run_id: agent_run.id,
        issue_id: issue.id
      )
    end

    # Extracts answers from the issue's clarifying-questions answer comment
    # and maps them to the feature brief structure (RDR-053 §2).
    def assemble_feature_brief_from_answers(issue)
      # Build a base brief from the existing issue title and body.
      title = issue.title.to_s.sub(/\A\[Feature\]\s*/, "")
      problem = issue.body.to_s

      # Extract answers from the latest answer comment.
      answers = ClarifyingQuestions::ExtractAnswerPairs.call(
        project: project,
        issue_comments: issue_comments(issue),
        issue: issue
      ).qa_pairs

      desired_behavior = ""
      constraints = []
      rejected_alternatives = ""
      scope_in = ""
      # The single scope question covers both in and out of scope; without
      # semantic splitting (an AI concern, not a code concern) the combined
      # answer lands in "in". nil for "out" suppresses the empty section
      # downstream (Array(nil).blank? is true; Array("").blank? is not).
      scope_out = nil
      done_criteria = ""

      answers&.each do |qa|
        question = qa[:question].to_s.downcase
        answer = qa[:answer].to_s.strip
        next if answer.blank?

        if question.include?("desired behavior")
          desired_behavior = answer
        elsif question.include?("constraint")
          constraints << answer unless answer.blank?
        elsif question.include?("alternative")
          rejected_alternatives = answer
        elsif question.include?("scope")
          scope_in = answer
        elsif question.include?("done")
          done_criteria = answer
        end
      end

      {
        "title" => title,
        "problem" => problem,
        "desired_behavior" => desired_behavior,
        "constraints" => constraints,
        "rejected_alternatives" => rejected_alternatives,
        "scope" => { "in" => scope_in, "out" => scope_out },
        "done_criteria" => done_criteria
      }
    end

    def issue_comments(issue)
      return [] unless project.github_credential_present?

      project.client&.issue_comments(project.full_name, issue.github_number) || []
    rescue GithubClient::Error
      []
    end
  end
end
