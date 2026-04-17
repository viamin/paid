# frozen_string_literal: true

require "rails_helper"

RSpec.describe TenantScoped do
  # Use a real model (Project) to test scoping behavior since anonymous classes
  # have issues with ActiveRecord internals (model_name, demodulize, etc.)
  let(:account_a) { create(:account) }
  let(:account_b) { create(:account) }

  describe ".for_tenant" do
    it "scopes records to the given account" do
      project_a = create(:project, account: account_a)
      create(:project, account: account_b)

      results = Project.for_tenant(account_a)
      expect(results).to contain_exactly(project_a)
    end
  end

  describe ".for_current_tenant" do
    it "scopes records to Current.account when set" do
      project_a = create(:project, account: account_a)
      create(:project, account: account_b)

      Current.account = account_a
      results = Project.for_current_tenant
      expect(results).to contain_exactly(project_a)
    ensure
      Current.account = nil
    end

    it "returns no records when Current.account is nil" do
      create(:project, account: account_a)
      create(:project, account: account_b)

      Current.account = nil
      results = Project.for_current_tenant
      expect(results).to be_empty
    end
  end
end
