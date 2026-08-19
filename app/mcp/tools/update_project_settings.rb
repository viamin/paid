# frozen_string_literal: true

module Tools
  class UpdateProjectSettings < BaseTool
    authorize :update?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    # Operational and automation settings safe to change from chat. Excludes
    # repo identity (name/owner/repo/github_id), credentials (github_token_id,
    # github_installation_id, webhook_secret, git_push_fallback_token_id), and
    # counter/timestamp bookkeeping columns.
    PERMITTED_ATTRIBUTES = %i[
      active
      paused
      auto_pick_enabled
      automation_on_label_enabled
      auto_fix_merge_conflicts
      auto_add_labels_enabled
      auto_enhance_enabled
      knowledge_evolution_enabled
      pr_aggregation_enabled
      inherit_priority_labels
      allow_bot_authored_pr_auto_merge
      auto_merge_mode
      auto_release_granularity
      merge_method
      owner_reviewer_login
      review_settings
      quality_gate_settings
      interop_settings
      auto_pick_skip_labels
      priority_labels
      model_preferences
      fitness_settings
      data_classification
      max_execution_seconds
      max_tokens_per_run
      plan_review_timeout_hours
      max_draft_review_rounds
      max_pr_followup_runs
      max_pr_auto_continue_tokens
      token_limit_warning_threshold
      poll_interval_seconds
    ].freeze

    def self.tool_name = "update_project_settings"
    def self.write_operation? = true

    def self.description
      "Update operational and automation settings for a project."
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          project_id: { type: "integer", description: "The project ID" },
          settings: { type: "object" },
          confirmed: { type: "boolean" }
        },
        required: %w[project_id settings confirmed]
      }
    end

    def self.available_to?(user:)
      return false if user.blank?

      Pundit.policy_scope!(user, Project).any? do |project|
        policy_allows?(user:, record: project, query: :update?, policy_class: ProjectPolicy)
      end
    rescue Pundit::NotAuthorizedError
      false
    end

    def perform(project_id:, settings:, confirmed:)
      raise ArgumentError, "Confirmation required: set confirmed=true to update project settings" unless confirmed
      raise ArgumentError, "settings must be an object" unless settings.is_a?(Hash)

      project = project_for(project_id)
      attrs = settings.symbolize_keys.slice(*PERMITTED_ATTRIBUTES)
      project.update!(attrs)
      record_activity!(project) if project.saved_changes.except("updated_at").any?
      serialize(project)
    end

    private

    def project_for(project_id)
      @projects_by_id ||= {}
      @projects_by_id[project_id] ||= policy_scope(Project).find(project_id)
    end

    def record_activity!(project)
      Accounts::RecordActivity.call(
        account:,
        actor: user,
        action: "project.settings_changed",
        subject: project,
        metadata: { changed_fields: project.saved_changes.except("updated_at").keys }
      )
    end

    def serialize(project)
      PERMITTED_ATTRIBUTES.each_with_object({ id: project.id }) do |attribute, hash|
        hash[attribute] = project.public_send(attribute)
      end
    end
  end
end
