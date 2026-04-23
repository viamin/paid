# frozen_string_literal: true

module TenantConfigurations
  class ApplyProjectDefaults
    def self.call(project)
      new(project).call
    end

    def initialize(project)
      @project = project
      @tenant_setting = project.account.tenant_setting
    end

    def call
      return unless tenant_setting

      apply_cost_budgets
      apply_quality_thresholds
    end

    private

    attr_reader :project, :tenant_setting

    def apply_cost_budgets
      tenant_setting.default_cost_budget_attributes.each do |attributes|
        project.cost_budgets.find_or_create_by!(budget_type: attributes.fetch("budget_type")) do |budget|
          budget.assign_attributes(attributes.except("budget_type"))
        end
      end
    end

    def apply_quality_thresholds
      thresholds = tenant_setting.quality_thresholds
      return if thresholds.blank? || project.quality_gate_settings.present?

      project.update!(quality_gate_settings: tenant_setting.effective_quality_thresholds)
    end
  end
end
