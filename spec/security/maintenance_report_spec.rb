# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261116223347_create_maintenance_reports_and_findings")

RSpec.describe MaintenanceReport, :tenant_isolation do
  # Schema dumps preserve the fx reference guards. RLS policies are installed
  # by migrations, so install that migration's policies for this isolated test.
  before do
    connection = ActiveRecord::Base.connection
    %w[maintenance_reports maintenance_findings maintenance_finding_occurrences].each do |table|
      next if connection.select_value("SELECT 1 FROM pg_policies WHERE tablename = '#{table}' AND policyname = 'tenant_isolation'")

      ActiveRecord::Migration.suppress_messages do
        CreateMaintenanceReportsAndFindings.new.send(:enable_tenant_rls!, table)
      end
    end
  end

  # @spec POSTGRESQL-PERSISTENCE-006 MAINT-016 MAINT-025
  it "exposes only the current tenant's reports, findings and occurrences" do
    projects = TenantContext.with_system_access { [ create(:project), create(:project) ] }
    reports = TenantContext.with_system_access do
      projects.map do |project|
        run = create(:agent_run, :manual, project:, issue: nil, goal: "maintenance", maintenance_guidance: "Inspect")
        MaintenanceReports::Persist.call(run:, findings: [ {
          category: "unused_code", claim: "Legacy callback may be unused", symbols: [ "Legacy#call" ],
          locations: [], analyzer_provenance: {}, verification_disposition: "unverified"
        } ])
      end
    end

    TenantContext.with(projects.first.account) do
      expect(described_class.all).to contain_exactly(reports.first)
      expect(MaintenanceFinding.all).to contain_exactly(reports.first.finding_occurrences.sole.maintenance_finding)
      expect(MaintenanceFindingOccurrence.all).to contain_exactly(reports.first.finding_occurrences.sole)
    end
    TenantContext.with(nil) do
      expect(described_class.count).to eq(0)
      expect(MaintenanceFinding.count).to eq(0)
      expect(MaintenanceFindingOccurrence.count).to eq(0)
    end
  end
end
