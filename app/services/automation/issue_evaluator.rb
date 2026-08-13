# frozen_string_literal: true

module Automation
  class IssueEvaluator
    include LabelPolicy

    def initialize(record:)
      @record = record
      @project = record.project
    end

    def call
      label_decision_for(project, record)
    end

    private

    attr_reader :record, :project
  end
end
