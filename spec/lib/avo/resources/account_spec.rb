# frozen_string_literal: true

require "rails_helper"

RSpec.describe Avo::Resources::Account, :no_db do
  it "registers the expected account fields" do
    resource = described_class.new(view: :show).detect_fields

    expect(described_class.model_class).to eq(Account)
    expect(described_class.authorization_policy).to eq(OperatorConsole::AccountPolicy)
    expect(resource.get_field_definitions.map(&:id)).to include(
      :name, :slug, :plan, :status, :default_max_tokens_per_run, :suspended_at, :deactivated_at
    )
  end

  it "keeps the operator-only lifecycle actions attached to the resource" do
    file, line = described_class.instance_method(:actions).source_location
    source = File.readlines(file)[(line - 1), 6].join

    expect(source).to include("action Avo::Actions::SuspendAccount")
    expect(source).to include("action Avo::Actions::ReactivateAccount")
    expect(source).to include("action Avo::Actions::DeactivateAccount")
  end

  describe "related resources" do
    it "registers the expected user fields and policy" do
      resource = Avo::Resources::User.new(view: :show).detect_fields

      expect(Avo::Resources::User.model_class).to eq(User)
      expect(Avo::Resources::User.authorization_policy).to eq(OperatorConsole::UserPolicy)
      expect(resource.get_field_definitions.map(&:id)).to include(:email, :name, :account_id, :remember_created_at)
    end

    it "registers the expected account membership fields and policy" do
      resource = Avo::Resources::AccountMembership.new(view: :show).detect_fields

      expect(Avo::Resources::AccountMembership.model_class).to eq(AccountMembership)
      expect(Avo::Resources::AccountMembership.authorization_policy).to eq(OperatorConsole::AccountMembershipPolicy)
      expect(resource.get_field_definitions.map(&:id)).to include(:account_id, :user_id, :role)
    end

    it "registers the expected project membership fields and policy" do
      resource = Avo::Resources::ProjectMembership.new(view: :show).detect_fields

      expect(Avo::Resources::ProjectMembership.model_class).to eq(ProjectMembership)
      expect(Avo::Resources::ProjectMembership.authorization_policy).to eq(OperatorConsole::ProjectMembershipPolicy)
      expect(resource.get_field_definitions.map(&:id)).to include(:project_id, :user_id, :role)
    end

    it "registers the expected tenant setting fields and policy" do
      resource = Avo::Resources::TenantSetting.new(view: :show).detect_fields

      expect(Avo::Resources::TenantSetting.model_class).to eq(TenantSetting)
      expect(Avo::Resources::TenantSetting.authorization_policy).to eq(OperatorConsole::TenantSettingPolicy)
      expect(resource.get_field_definitions.map(&:id)).to include(
        :max_concurrent_runs,
        :max_projects,
        :max_users,
        :max_tokens_per_run,
        :allowed_runner_keys,
        :runner_preferences,
        :default_budgets,
        :guardrails,
        :quality_thresholds,
        :agent_settings,
        :worker_settings,
        :features
      )
    end
  end
end
