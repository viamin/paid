# frozen_string_literal: true

module Tools
  class InboxTool < BaseTool
    authorize :index?, ->(_args) { :inbox }, policy_class: InboxPolicy

    private

    def project_for(project_id)
      policy_scope(Project).find(project_id)
    end

    def valid_kind(kind)
      return if kind.blank?

      Inbox::Queue::KINDS.include?(kind) ? kind : nil
    end

    def valid_scope(scope)
      return Inbox::Queue::ACTIONABLE_SCOPE if scope.blank?

      Inbox::Queue::SCOPES.include?(scope) ? scope : Inbox::Queue::ACTIONABLE_SCOPE
    end

    def valid_sort(sort)
      Inbox::Queue::SORTS.key?(sort) ? sort : Inbox::Queue::DEFAULT_SORT
    end
  end
end
