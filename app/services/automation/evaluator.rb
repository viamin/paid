# frozen_string_literal: true

module Automation
  class Evaluator
    def self.for(record)
      evaluator_class =
        if record.is_pull_request?
          PullRequestEvaluator
        else
          IssueEvaluator
        end

      evaluator_class.new(record:)
    end
  end
end
