# frozen_string_literal: true

module ProjectDelegation
  # Explicit conservative rollback. The posture is revised, not deleted, so
  # existing admissions retain their original evidence for audit and recheck.
  # @spec PROJECT-DELEGATION-006
  class Rollback
    def self.call(...)
      new(...).call
    end

    def initialize(project:, actor:, reason:)
      @project = project
      @actor = actor
      @reason = reason.to_s.strip
    end

    def call
      raise ArgumentError, "rollback reason is required" if reason.blank?

      SelectPosture.call(project:, actor:, level: Posture::CONSERVATIVE, reason:)
    end

    private

    attr_reader :actor, :project, :reason
  end
end
