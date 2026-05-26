# frozen_string_literal: true

class QualityFeedbackService
  CheckResult = Struct.new(:type, :success, :errors, :warnings, :raw_output, keyword_init: true) do
    def success?
      success
    end

    def to_h
      {
        type: type,
        success: success,
        errors: errors,
        warnings: warnings,
        raw_output: raw_output
      }
    end
  end

  attr_reader :worktree_path, :language

  def initialize(worktree_path:, language:)
    @worktree_path = worktree_path
    @language = language.to_s
  end

  def mutation_result
    return empty_result(:mutation_test) unless language == "ruby"

    QualityFeedback::ParseMutant.call(worktree_path: worktree_path)
  end

  private

  def empty_result(type)
    CheckResult.new(type:, success: true, errors: [], warnings: [], raw_output: "")
  end
end
