# frozen_string_literal: true

module Issues
  class AutoPickProjectGate
    def self.call(project)
      new(project).call
    end

    def initialize(project)
      @project = project
    end

    def call
      return false unless project.auto_pick_enabled?
      return false if project.quality_paused?
      return false if project.scheduler_paused?
      return false if project.account&.scheduler_paused?
      return false unless owner

      true
    end

    private

    attr_reader :project

    def owner
      @owner ||= project.effective_owner
    end
  end
end
