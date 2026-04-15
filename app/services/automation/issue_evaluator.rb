# frozen_string_literal: true

module Automation
  class IssueEvaluator
    include LabelPolicy

    def initialize(record:, explicit_pr_decisions: false)
      @record = record
      @project = record.project
      @explicit_pr_decisions = explicit_pr_decisions
    end

    def call
      label_decision_for(project, record)
    end

    private

    attr_reader :record, :project, :explicit_pr_decisions
  end
end
