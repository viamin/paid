# frozen_string_literal: true

module Inbox
  # A small, deterministic presentation contract shared by every Inbox surface.
  # It only reads the queue entry and its persisted guidance; it never asks an
  # LLM to reinterpret an operator decision while rendering.
  # The lane copy keeps every supported kind explicit, so this projection is
  # intentionally longer than a typical service object.
  # @spec OPERATOR-INBOX-027
  class DecisionBrief
    Result = Data.define(:goal, :changed, :decision, :recommendation,
      :recommendation_reason, :waiting_work, :primary_action, :next_state, :unknown) do
      def to_h
        members.index_with { |member| public_send(member) }.compact
      end

      def list_summary
        [ decision, changed ].compact.uniq.join(" — ").truncate(220)
      end
    end

    ACTIONS = {
      Queue::CLARIFYING_QUESTIONS_KIND => [ "Answer the question", "Paid can continue with your answer." ],
      Queue::PLAN_REVIEW_KIND => [ "Review the plan", "Planning continues with the recorded decision." ],
      Queue::MERGE_APPROVAL_KIND => [ "Review merge readiness", "Paid will follow the recorded merge decision." ],
      Queue::ACTION_REQUIRED_KIND => [ "Complete remediation", "Blocked work can resume after the remediation is recorded." ],
      Queue::ESCALATED_PR_KIND => [ "Resolve the pull request block", "Paid can resume pull request processing after the block clears." ],
      Queue::MANUAL_REVIEW_KIND => [ "Review recovery", "Paid will only resume through the selected recovery path." ],
      Queue::INTENT_CONFORMANCE_KIND => [ "Record the conformance decision", "Paid will follow the recorded fix, exception, or amendment path." ],
      Queue::FEATURE_DECISION_KIND => [ "Resolve the feature decision", "Paid will reassess feature readiness from the recorded response." ],
      Queue::RETRY_LIMITED_KIND => [ "Choose a recovery path", "Paid can resume only through the selected recovery path." ],
      Queue::CHANGE_INTENT_DRAFT_KIND => [ "Review the intent change", "Paid will apply the recorded disposition to the draft." ],
      Queue::PARTIAL_CLOSEOUT_KIND => [ "Resolve remaining work", "The issue can be reassessed after the remaining work is recorded." ],
      Queue::TEST_REVIEW_PENDING_KIND => [ "Review the proposed tests", "Implementation can begin after the test-review gate clears." ],
      Queue::PROJECT_SETUP_PENDING_KIND => [ "Complete project setup", "Paid will recheck readiness after setup evidence is recorded." ],
      Queue::TRACEABILITY_GAP_KIND => [ "Resolve the traceability finding", "Reconciliation will verify the recorded resolution." ],
      Queue::LAYERED_VERIFICATION_FINDING_KIND => [ "Record the verification decision", "Paid records the decision without changing project artifacts." ],
      Queue::DEPENDENCY_CYCLE_KIND => [ "Resolve the dependency cycle", "A later synchronization will confirm whether the cycle cleared." ]
    }.freeze

    DECISIONS = {
      Queue::CLARIFYING_QUESTIONS_KIND => nil,
      Queue::PLAN_REVIEW_KIND => "Approve, reject, or revise the proposed plan.",
      Queue::MERGE_APPROVAL_KIND => "Approve the pull request for merge or hold it for changes.",
      Queue::ACTION_REQUIRED_KIND => "Complete the required remediation.",
      Queue::ESCALATED_PR_KIND => "Choose how to unblock the pull request.",
      Queue::MANUAL_REVIEW_KIND => "Choose whether and how Paid should resume.",
      Queue::INTENT_CONFORMANCE_KIND => "Choose a fix, bounded exception, or design amendment.",
      Queue::FEATURE_DECISION_KIND => "Answer the open feature decision or approve the ready design.",
      Queue::RETRY_LIMITED_KIND => "Choose how to recover the stopped issue.",
      Queue::CHANGE_INTENT_DRAFT_KIND => "Accept, revise, or reject the proposed intent change.",
      Queue::PARTIAL_CLOSEOUT_KIND => "Choose how to finish the remaining acceptance criteria.",
      Queue::TEST_REVIEW_PENDING_KIND => "Approve the proposed tests or request changes.",
      Queue::PROJECT_SETUP_PENDING_KIND => "Complete the missing setup or start a readiness bootstrap.",
      Queue::TRACEABILITY_GAP_KIND => "Resolve, assign, or recheck the traceability finding.",
      Queue::LAYERED_VERIFICATION_FINDING_KIND => "Request repair, persist a clarification, or defer the finding.",
      Queue::DEPENDENCY_CYCLE_KIND => "Choose which dependency declaration should change."
    }.freeze

    UNKNOWNS = {
      Queue::PLAN_REVIEW_KIND => "Which plan disposition should Paid record?",
      Queue::MERGE_APPROVAL_KIND => "Should Paid merge this pull request or hold it for changes?",
      Queue::ACTION_REQUIRED_KIND => "What remediation must be completed?",
      Queue::ESCALATED_PR_KIND => "Which recovery should clear the pull request block?",
      Queue::MANUAL_REVIEW_KIND => "Which authorized recovery path should Paid follow?",
      Queue::INTENT_CONFORMANCE_KIND => "Should Paid fix the pull request, grant an exception, or amend the design?",
      Queue::FEATURE_DECISION_KIND => "What feature direction should Paid record?",
      Queue::RETRY_LIMITED_KIND => "Which recovery should Paid use for the stopped issue?",
      Queue::CHANGE_INTENT_DRAFT_KIND => "Should Paid accept, revise, or reject this intent change?",
      Queue::PARTIAL_CLOSEOUT_KIND => "Who will own the remaining acceptance work?",
      Queue::TEST_REVIEW_PENDING_KIND => "Should implementation proceed with these tests?",
      Queue::PROJECT_SETUP_PENDING_KIND => "Which missing setup step should be completed first?",
      Queue::TRACEABILITY_GAP_KIND => "Which work should own this traceability finding?",
      Queue::LAYERED_VERIFICATION_FINDING_KIND => "Should Paid request repair, persist clarification, or defer?",
      Queue::DEPENDENCY_CYCLE_KIND => "Which dependency declaration should be removed or corrected?"
    }.freeze

    def self.call(entry:)
      new(entry:).call
    end

    def self.list_summary(entry:)
      new(entry:).list_summary
    end

    def initialize(entry:)
      raise ArgumentError, "unknown inbox kind: #{entry.kind}" unless Queue::KINDS.include?(entry.kind)

      @entry = entry
    end

    def call
      Result.new(goal:, changed:, decision:, recommendation:, recommendation_reason:, waiting_work:,
        primary_action: action.first, next_state: action.last, unknown:)
    end

    def list_summary
      [ decision, changed ].compact.uniq.join(" — ").truncate(220)
    end

    private

    attr_reader :entry

    def goal
      entry.title.presence || "Current project work"
    end

    def changed
      return "Product direction is needed before work can continue." if entry.clarifying_questions?
      return "This issue still has remaining acceptance work." if entry.partial_closeout?

      entry.summary.presence || "This work is waiting for a human decision."
    end

    def decision
      return question_payload[:question].presence || "Answer the product question." if entry.clarifying_questions?

      DECISIONS.fetch(entry.kind)
    end

    def recommendation
      return @recommendation if defined?(@recommendation)

      @recommendation = case entry.kind
      when Queue::CLARIFYING_QUESTIONS_KIND then question_payload[:recommendation]
      when Queue::ACTION_REQUIRED_KIND then entry.tasks.first.to_s.presence
      when Queue::PARTIAL_CLOSEOUT_KIND then partial_closeout_recommendation
      when Queue::MERGE_APPROVAL_KIND then entry.guidance&.fetch(:instruction, nil)
      end
    end

    def recommendation_reason
      return question_recommendation_reason if entry.clarifying_questions?
      return "This is the first recorded remediation step." if entry.action_required? && recommendation
      return "This is the first unresolved prerequisite." if entry.partial_closeout? && recommendation
      "This guidance comes from the current merge assessment." if entry.merge_approval? && recommendation
    end

    def waiting_work
      return "Work is waiting for your answer." if entry.clarifying_questions?
      return "Work is waiting for the required remediation." if entry.action_required?
      return "Automation is waiting for an authorized recovery decision." if entry.manual_review?
      return "Remaining acceptance work is waiting for an owner." if entry.partial_closeout?

      "Work is waiting for this decision."
    end

    def unknown
      return unless recommendation.blank?

      entry.clarifying_questions? ? decision : UNKNOWNS.fetch(entry.kind)
    end

    def action
      ACTIONS.fetch(entry.kind)
    end

    def question_payload
      @question_payload ||= ClarifyingQuestions::QuestionPayload.call(question: entry.questions.first)
    end

    def question_recommendation_reason
      return unless recommendation

      question_payload[:rationale] || "Supported by: #{question_payload[:evidence_references].join('; ')}."
    end

    def partial_closeout_recommendation
      reference = entry.tasks.first.to_s.presence
      return unless reference

      title = local_prerequisite_title(reference)
      return "Resolve the prerequisite: #{title}." if title

      repository = reference.delete_prefix("#").split("#", 2).first
      "Resolve the first unresolved prerequisite#{" in #{repository}" if reference.include?("#") && !reference.start_with?("#")}."
    end

    def local_prerequisite_title(reference)
      return unless entry.issue && reference.match?(/\A#\d+\z/)

      number = reference.delete_prefix("#").to_i
      if entry.issue.association(:issue_dependencies).loaded?
        dependency = entry.issue.issue_dependencies.find do |candidate|
          depends_on = candidate.depends_on_issue
          depends_on&.project_id == entry.project.id && depends_on.github_number == number
        end
        return dependency&.depends_on_issue&.title
      end

      entry.issue.dependencies.find_by(project: entry.project, github_number: number)&.title
    end
  end
end
