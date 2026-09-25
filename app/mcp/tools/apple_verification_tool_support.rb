# frozen_string_literal: true

module Tools
  module AppleVerificationToolSupport
    def self.included(base)
      base.extend(ClassMethods)
    end

    module ClassMethods
      def available_to?(user:)
        run_agent_available_to?(user:)
      end

      def mcp_available? = true
      def requires_agent_run? = true
    end

    private

    def project_for(project_id)
      @projects_by_id ||= {}
      @projects_by_id[project_id] ||= policy_scope(Project).find(project_id)
    rescue ActiveRecord::RecordNotFound
      raise Pundit::NotAuthorizedError, "Project not found or not accessible"
    end

    def agent_run_for(project_id, agent_run_id)
      unless agent_run&.id.to_s == agent_run_id.to_s
        raise Pundit::NotAuthorizedError, "Agent run not found or not accessible"
      end

      project_for(project_id).agent_runs.where(id: agent_run.id, initiating_user: user).find(agent_run_id)
    rescue ActiveRecord::RecordNotFound
      raise Pundit::NotAuthorizedError, "Agent run not found or not accessible"
    end

    def with_agent_tool_errors
      yield
    rescue AppleVerification::AgentTools::CapabilityDisabledError,
           AppleVerification::AgentTools::AuthorityError => e
      raise Pundit::NotAuthorizedError, e.message
    rescue AppleVerification::AgentTools::ModeUnavailableError,
           AppleVerification::AgentTools::WorkflowUnavailableError,
           AppleVerification::AgentTools::QuotaExceededError,
           AppleVerification::AgentTools::CaptureNotDeclaredError => e
      raise ArgumentError, e.message
    end
  end
end
