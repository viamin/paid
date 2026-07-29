# frozen_string_literal: true

module OperatorTools
  module Inventory
    RESOURCES = [
      {
        resource: "accounts",
        policy: "OperatorConsole::AccountPolicy",
        operator_only: true,
        avo_resource: "Avo::Resources::Account",
        tool_names: %w[
          operator_list_accounts
          operator_get_account
          operator_suspend_account
          operator_reactivate_account
          operator_deactivate_account
        ]
      },
      {
        resource: "account_activity_events",
        policy: "OperatorConsole::AccountActivityEventPolicy",
        operator_only: true,
        avo_resource: "Avo::Resources::AccountActivityEvent",
        tool_names: %w[operator_list_account_activity_events operator_get_account_activity_event]
      },
      {
        resource: "account_memberships",
        policy: "OperatorConsole::AccountMembershipPolicy",
        operator_only: true,
        avo_resource: "Avo::Resources::AccountMembership",
        tool_names: %w[operator_list_account_memberships operator_get_account_membership]
      },
      {
        resource: "pre_commit_requirements",
        policy: "OperatorConsole::PreCommitRequirementPolicy",
        operator_only: true,
        avo_resource: "Avo::Resources::PreCommitRequirement",
        tool_names: %w[operator_list_pre_commit_requirements operator_get_pre_commit_requirement]
      },
      {
        resource: "project_memberships",
        policy: "OperatorConsole::ProjectMembershipPolicy",
        operator_only: true,
        avo_resource: "Avo::Resources::ProjectMembership",
        tool_names: %w[operator_list_project_memberships operator_get_project_membership]
      },
      {
        resource: "style_guides",
        policy: "OperatorConsole::StyleGuidePolicy",
        operator_only: true,
        avo_resource: "Avo::Resources::StyleGuide",
        tool_names: %w[
          operator_list_style_guides
          operator_get_style_guide
          operator_recompress_style_guides
        ]
      },
      {
        resource: "tenant_settings",
        policy: "OperatorConsole::TenantSettingPolicy",
        operator_only: true,
        avo_resource: "Avo::Resources::TenantSetting",
        tool_names: %w[operator_list_tenant_settings operator_get_tenant_setting]
      },
      {
        resource: "users",
        policy: "OperatorConsole::UserPolicy",
        operator_only: true,
        avo_resource: "Avo::Resources::User",
        tool_names: %w[operator_list_users operator_get_user]
      }
    ].freeze

    PRELIMINARY_SURFACES_NOT_IN_AVO = [
      "cross-tenant user impersonation flows",
      "system-level provider catalog edits",
      "global feature flags / kill switches",
      "manual self-heal remediation triggers"
    ].freeze
  end
end
