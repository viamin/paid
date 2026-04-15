# frozen_string_literal: true

module Automation
  class Evaluator
    def self.for(record, explicit_pr_decisions: false)
      evaluator_class =
        if record.is_pull_request?
          PullRequestEvaluator
        else
          IssueEvaluator
        end

      evaluator_class.new(record:, explicit_pr_decisions:)
    end
  end
end
