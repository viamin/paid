# frozen_string_literal: true

module Issues
  class AutoPickProjectGate
    def self.call(project, owner: nil)
      new(project, owner: owner).call
    end

    def initialize(project, owner: nil)
      @project = project
      @preresolved_owner = owner
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

    attr_reader :project, :preresolved_owner

    def owner
      @owner ||= preresolved_owner || project.effective_owner
    end
  end
end
