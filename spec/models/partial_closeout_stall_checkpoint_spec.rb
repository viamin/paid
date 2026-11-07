# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261107150100_enable_rls_on_partial_closeout_stall_projections")

RSpec.describe PartialCloseoutStallCheckpoint do # @spec PARTIAL-CLOSEOUT-042
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account, created_by: create(:user, account: account)) }

  describe "#successful?" do
    it "distinguishes an evaluated project from a never-successful checkpoint" do
      checkpoint = described_class.create!(account: account, project: project)

      expect(checkpoint).not_to be_successful

      checkpoint.update!(computed_at: Time.current, input_watermark: Time.current, generation: 1)

      expect(checkpoint).to be_successful
    end
  end

  describe "tenant row-level scoping", :tenant_isolation do
    around do |example|
      skip "requires CREATE ROLE privilege for RLS policy checks" unless can_manage_roles?

      had_rls = projections_have_rls?
      install_projection_policies unless had_rls
      setup_restricted_role
      example.run
    ensure
      ActiveRecord::Base.connection.execute("RESET ROLE")
      cleanup_restricted_role
      uninstall_projection_policies unless had_rls
    end

    it "only exposes stalls and checkpoints for the current account" do
      account_a = TenantContext.with_system_access { create(:account) }
      account_b = TenantContext.with_system_access { create(:account) }
      stall_a, checkpoint_a = seed_projection_for(account_a)
      seed_projection_for(account_b)

      as_restricted_role do
        TenantContext.with(account_a) do
          expect(PartialCloseoutStall.all).to contain_exactly(stall_a)
          expect(described_class.all).to contain_exactly(checkpoint_a)
        end
      end
    end

    private

    def seed_projection_for(account)
      TenantContext.with_system_access do
        project = create(:project, account: account, created_by: create(:user, account: account))
        issue = create(:issue, project: project)
        stall = PartialCloseoutStall.create!(
          account: account, project: project, issue: issue,
          evidence_digest: SecureRandom.hex(32), projection_generation: 1
        )
        checkpoint = described_class.create!(account: account, project: project, computed_at: Time.current)
        [ stall, checkpoint ]
      end
    end

    def install_projection_policies
      ActiveRecord::Migration.suppress_messages do
        EnableRlsOnPartialCloseoutStallProjections.new.up
      end
    end

    def uninstall_projection_policies
      ActiveRecord::Migration.suppress_messages do
        EnableRlsOnPartialCloseoutStallProjections.new.down
      end
    end

    def projections_have_rls?
      ActiveRecord::Base.connection.select_value(<<~SQL.squish).to_i.positive?
        SELECT COUNT(*)
        FROM pg_policies
        WHERE schemaname = 'public'
          AND tablename IN ('partial_closeout_stall_checkpoints', 'partial_closeout_stalls')
          AND policyname = 'tenant_isolation'
      SQL
    end

    def setup_restricted_role
      cleanup_restricted_role
      connection = ActiveRecord::Base.connection
      connection.execute("CREATE ROLE paid_rls_spec NOLOGIN")
      connection.execute("GRANT USAGE ON SCHEMA public TO paid_rls_spec")
      connection.execute("GRANT SELECT ON ALL TABLES IN SCHEMA public TO paid_rls_spec")
      connection.execute("GRANT paid_rls_spec TO current_user")
    end

    def as_restricted_role
      ActiveRecord::Base.connection.execute("SET ROLE paid_rls_spec")
      yield
    ensure
      ActiveRecord::Base.connection.execute("RESET ROLE")
    end

    def cleanup_restricted_role
      return unless ActiveRecord::Base.connection.select_value("SELECT 1 FROM pg_roles WHERE rolname = 'paid_rls_spec'")

      connection = ActiveRecord::Base.connection
      connection.execute("GRANT paid_rls_spec TO current_user")
      connection.execute("DROP OWNED BY paid_rls_spec")
      connection.execute("DROP ROLE IF EXISTS paid_rls_spec")
    end

    def can_manage_roles?
      ActiveModel::Type::Boolean.new.cast(
        ActiveRecord::Base.connection.select_value(<<~SQL.squish)
          SELECT rolcreaterole
          FROM pg_roles
          WHERE rolname = current_user
        SQL
      )
    end
  end
end
