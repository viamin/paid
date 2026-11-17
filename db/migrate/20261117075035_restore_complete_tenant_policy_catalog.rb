# frozen_string_literal: true

# The earlier schema-bootstrap repair replayed only selected migration groups.
# Restore the complete, current policy definitions (not their older baseline
# versions), including tightened write predicates and projection policies.
# Frozen structural reference: migrated main 2fb3a7103, 224 policies; no business
# records. https://github.com/viamin/paid/pull/5135#issuecomment-6940836230
# @spec POSTGRESQL-PERSISTENCE-001 POSTGRESQL-PERSISTENCE-006 POSTGRESQL-PERSISTENCE-012
class RestoreCompleteTenantPolicyCatalog < ActiveRecord::Migration[8.1]
  def up
    # Transactional policy DDL changes no rows. Keep the repair atomic and
    # retain Strong Migrations' lock timeout rather than exposing partial RLS.
    safety_assured do
      # Avoid printing the complete structural catalog into deployment logs.
      suppress_messages do
        execute <<~'SQL'
        DROP POLICY IF EXISTS tenant_isolation_select ON public.configuration_bundles;
        DROP POLICY IF EXISTS tenant_isolation_insert ON public.configuration_bundles;
        DROP POLICY IF EXISTS tenant_isolation_update ON public.configuration_bundles;
        DROP POLICY IF EXISTS tenant_isolation_delete ON public.configuration_bundles;
        DROP POLICY IF EXISTS "tenant_isolation_delete" ON "public"."ab_test_assignments";
        CREATE POLICY "tenant_isolation_delete" ON "public"."ab_test_assignments" AS PERMISSIVE FOR DELETE TO PUBLIC
          USING ((paid_tenant_bypass() OR ((EXISTS ( SELECT 1
           FROM (ab_tests
             JOIN prompts ON ((prompts.id = ab_tests.prompt_id)))
          WHERE ((ab_tests.id = ab_test_assignments.ab_test_id) AND (prompts.account_id = paid_current_account_id()) AND ((prompts.project_id IS NULL) OR (EXISTS ( SELECT 1
                   FROM projects
                  WHERE ((projects.id = prompts.project_id) AND (projects.account_id = paid_current_account_id())))))))) AND (EXISTS ( SELECT 1
           FROM (agent_runs
             JOIN projects ON ((projects.id = agent_runs.project_id)))
          WHERE ((agent_runs.id = ab_test_assignments.agent_run_id) AND (projects.account_id = paid_current_account_id())))))));
        DROP POLICY IF EXISTS "tenant_isolation_insert" ON "public"."ab_test_assignments";
        CREATE POLICY "tenant_isolation_insert" ON "public"."ab_test_assignments" AS PERMISSIVE FOR INSERT TO PUBLIC
          WITH CHECK ((paid_tenant_bypass() OR ((EXISTS ( SELECT 1
           FROM (ab_tests
             JOIN prompts ON ((prompts.id = ab_tests.prompt_id)))
          WHERE ((ab_tests.id = ab_test_assignments.ab_test_id) AND (prompts.account_id = paid_current_account_id()) AND ((prompts.project_id IS NULL) OR (EXISTS ( SELECT 1
                   FROM projects
                  WHERE ((projects.id = prompts.project_id) AND (projects.account_id = paid_current_account_id())))))))) AND (EXISTS ( SELECT 1
           FROM (agent_runs
             JOIN projects ON ((projects.id = agent_runs.project_id)))
          WHERE ((agent_runs.id = ab_test_assignments.agent_run_id) AND (projects.account_id = paid_current_account_id())))))));
        DROP POLICY IF EXISTS "tenant_isolation_select" ON "public"."ab_test_assignments";
        CREATE POLICY "tenant_isolation_select" ON "public"."ab_test_assignments" AS PERMISSIVE FOR SELECT TO PUBLIC
          USING ((paid_tenant_bypass() OR ((EXISTS ( SELECT 1
           FROM (ab_tests
             JOIN prompts ON ((prompts.id = ab_tests.prompt_id)))
          WHERE ((ab_tests.id = ab_test_assignments.ab_test_id) AND ((prompts.account_id IS NULL) OR (prompts.account_id = paid_current_account_id()))))) AND (EXISTS ( SELECT 1
           FROM (agent_runs
             JOIN projects ON ((projects.id = agent_runs.project_id)))
          WHERE ((agent_runs.id = ab_test_assignments.agent_run_id) AND (projects.account_id = paid_current_account_id())))))));
        DROP POLICY IF EXISTS "tenant_isolation_update" ON "public"."ab_test_assignments";
        CREATE POLICY "tenant_isolation_update" ON "public"."ab_test_assignments" AS PERMISSIVE FOR UPDATE TO PUBLIC
          USING ((paid_tenant_bypass() OR ((EXISTS ( SELECT 1
           FROM (ab_tests
             JOIN prompts ON ((prompts.id = ab_tests.prompt_id)))
          WHERE ((ab_tests.id = ab_test_assignments.ab_test_id) AND (prompts.account_id = paid_current_account_id()) AND ((prompts.project_id IS NULL) OR (EXISTS ( SELECT 1
                   FROM projects
                  WHERE ((projects.id = prompts.project_id) AND (projects.account_id = paid_current_account_id())))))))) AND (EXISTS ( SELECT 1
           FROM (agent_runs
             JOIN projects ON ((projects.id = agent_runs.project_id)))
          WHERE ((agent_runs.id = ab_test_assignments.agent_run_id) AND (projects.account_id = paid_current_account_id())))))))
          WITH CHECK ((paid_tenant_bypass() OR ((EXISTS ( SELECT 1
           FROM (ab_tests
             JOIN prompts ON ((prompts.id = ab_tests.prompt_id)))
          WHERE ((ab_tests.id = ab_test_assignments.ab_test_id) AND (prompts.account_id = paid_current_account_id()) AND ((prompts.project_id IS NULL) OR (EXISTS ( SELECT 1
                   FROM projects
                  WHERE ((projects.id = prompts.project_id) AND (projects.account_id = paid_current_account_id())))))))) AND (EXISTS ( SELECT 1
           FROM (agent_runs
             JOIN projects ON ((projects.id = agent_runs.project_id)))
          WHERE ((agent_runs.id = ab_test_assignments.agent_run_id) AND (projects.account_id = paid_current_account_id())))))));
        DROP POLICY IF EXISTS "tenant_isolation_delete" ON "public"."ab_test_variants";
        CREATE POLICY "tenant_isolation_delete" ON "public"."ab_test_variants" AS PERMISSIVE FOR DELETE TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM (ab_tests
             JOIN prompts ON ((prompts.id = ab_tests.prompt_id)))
          WHERE ((ab_tests.id = ab_test_variants.ab_test_id) AND (prompts.account_id = paid_current_account_id()) AND ((prompts.project_id IS NULL) OR (EXISTS ( SELECT 1
                   FROM projects
                  WHERE ((projects.id = prompts.project_id) AND (projects.account_id = paid_current_account_id()))))))))));
        DROP POLICY IF EXISTS "tenant_isolation_insert" ON "public"."ab_test_variants";
        CREATE POLICY "tenant_isolation_insert" ON "public"."ab_test_variants" AS PERMISSIVE FOR INSERT TO PUBLIC
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM (ab_tests
             JOIN prompts ON ((prompts.id = ab_tests.prompt_id)))
          WHERE ((ab_tests.id = ab_test_variants.ab_test_id) AND (prompts.account_id = paid_current_account_id()) AND ((prompts.project_id IS NULL) OR (EXISTS ( SELECT 1
                   FROM projects
                  WHERE ((projects.id = prompts.project_id) AND (projects.account_id = paid_current_account_id()))))))))));
        DROP POLICY IF EXISTS "tenant_isolation_select" ON "public"."ab_test_variants";
        CREATE POLICY "tenant_isolation_select" ON "public"."ab_test_variants" AS PERMISSIVE FOR SELECT TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM (ab_tests
             JOIN prompts ON ((prompts.id = ab_tests.prompt_id)))
          WHERE ((ab_tests.id = ab_test_variants.ab_test_id) AND ((prompts.account_id IS NULL) OR (prompts.account_id = paid_current_account_id())))))));
        DROP POLICY IF EXISTS "tenant_isolation_update" ON "public"."ab_test_variants";
        CREATE POLICY "tenant_isolation_update" ON "public"."ab_test_variants" AS PERMISSIVE FOR UPDATE TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM (ab_tests
             JOIN prompts ON ((prompts.id = ab_tests.prompt_id)))
          WHERE ((ab_tests.id = ab_test_variants.ab_test_id) AND (prompts.account_id = paid_current_account_id()) AND ((prompts.project_id IS NULL) OR (EXISTS ( SELECT 1
                   FROM projects
                  WHERE ((projects.id = prompts.project_id) AND (projects.account_id = paid_current_account_id()))))))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM (ab_tests
             JOIN prompts ON ((prompts.id = ab_tests.prompt_id)))
          WHERE ((ab_tests.id = ab_test_variants.ab_test_id) AND (prompts.account_id = paid_current_account_id()) AND ((prompts.project_id IS NULL) OR (EXISTS ( SELECT 1
                   FROM projects
                  WHERE ((projects.id = prompts.project_id) AND (projects.account_id = paid_current_account_id()))))))))));
        DROP POLICY IF EXISTS "tenant_isolation_delete" ON "public"."ab_tests";
        CREATE POLICY "tenant_isolation_delete" ON "public"."ab_tests" AS PERMISSIVE FOR DELETE TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM prompts
          WHERE ((prompts.id = ab_tests.prompt_id) AND (prompts.account_id = paid_current_account_id()) AND ((prompts.project_id IS NULL) OR (EXISTS ( SELECT 1
                   FROM projects
                  WHERE ((projects.id = prompts.project_id) AND (projects.account_id = paid_current_account_id()))))))))));
        DROP POLICY IF EXISTS "tenant_isolation_insert" ON "public"."ab_tests";
        CREATE POLICY "tenant_isolation_insert" ON "public"."ab_tests" AS PERMISSIVE FOR INSERT TO PUBLIC
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM prompts
          WHERE ((prompts.id = ab_tests.prompt_id) AND (prompts.account_id = paid_current_account_id()) AND ((prompts.project_id IS NULL) OR (EXISTS ( SELECT 1
                   FROM projects
                  WHERE ((projects.id = prompts.project_id) AND (projects.account_id = paid_current_account_id()))))))))));
        DROP POLICY IF EXISTS "tenant_isolation_select" ON "public"."ab_tests";
        CREATE POLICY "tenant_isolation_select" ON "public"."ab_tests" AS PERMISSIVE FOR SELECT TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM prompts
          WHERE ((prompts.id = ab_tests.prompt_id) AND ((prompts.account_id IS NULL) OR (prompts.account_id = paid_current_account_id())))))));
        DROP POLICY IF EXISTS "tenant_isolation_update" ON "public"."ab_tests";
        CREATE POLICY "tenant_isolation_update" ON "public"."ab_tests" AS PERMISSIVE FOR UPDATE TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM prompts
          WHERE ((prompts.id = ab_tests.prompt_id) AND (prompts.account_id = paid_current_account_id()) AND ((prompts.project_id IS NULL) OR (EXISTS ( SELECT 1
                   FROM projects
                  WHERE ((projects.id = prompts.project_id) AND (projects.account_id = paid_current_account_id()))))))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM prompts
          WHERE ((prompts.id = ab_tests.prompt_id) AND (prompts.account_id = paid_current_account_id()) AND ((prompts.project_id IS NULL) OR (EXISTS ( SELECT 1
                   FROM projects
                  WHERE ((projects.id = prompts.project_id) AND (projects.account_id = paid_current_account_id()))))))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."account_activity_events";
        CREATE POLICY "tenant_isolation" ON "public"."account_activity_events" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (account_id = paid_current_account_id())))
          WITH CHECK ((paid_tenant_bypass() OR (account_id = paid_current_account_id())));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."account_memberships";
        CREATE POLICY "tenant_isolation" ON "public"."account_memberships" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND (EXISTS ( SELECT 1
           FROM users
          WHERE ((users.id = account_memberships.user_id) AND (users.account_id = paid_current_account_id())))))))
          WITH CHECK ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND (EXISTS ( SELECT 1
           FROM users
          WHERE ((users.id = account_memberships.user_id) AND (users.account_id = paid_current_account_id())))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."accounts";
        CREATE POLICY "tenant_isolation" ON "public"."accounts" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (id = paid_current_account_id())))
          WITH CHECK ((paid_tenant_bypass() OR ((id = paid_current_account_id()) OR (paid_current_account_id() IS NULL))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."agent_coordination_signals";
        CREATE POLICY "tenant_isolation" ON "public"."agent_coordination_signals" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR ((EXISTS ( SELECT 1
           FROM (agent_runs
             JOIN projects ON ((projects.id = agent_runs.project_id)))
          WHERE ((agent_runs.id = agent_coordination_signals.source_agent_run_id) AND (projects.account_id = paid_current_account_id())))) AND ((target_agent_run_id IS NULL) OR (EXISTS ( SELECT 1
           FROM (agent_runs
             JOIN projects ON ((projects.id = agent_runs.project_id)))
          WHERE ((agent_runs.id = agent_coordination_signals.target_agent_run_id) AND (projects.account_id = paid_current_account_id()))))))))
          WITH CHECK ((paid_tenant_bypass() OR ((EXISTS ( SELECT 1
           FROM (agent_runs
             JOIN projects ON ((projects.id = agent_runs.project_id)))
          WHERE ((agent_runs.id = agent_coordination_signals.source_agent_run_id) AND (projects.account_id = paid_current_account_id())))) AND ((target_agent_run_id IS NULL) OR (EXISTS ( SELECT 1
           FROM (agent_runs
             JOIN projects ON ((projects.id = agent_runs.project_id)))
          WHERE ((agent_runs.id = agent_coordination_signals.target_agent_run_id) AND (projects.account_id = paid_current_account_id()))))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."agent_images";
        CREATE POLICY "tenant_isolation" ON "public"."agent_images" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (account_id = paid_current_account_id())))
          WITH CHECK ((paid_tenant_bypass() OR (account_id = paid_current_account_id())));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."agent_run_anomalies";
        CREATE POLICY "tenant_isolation" ON "public"."agent_run_anomalies" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = agent_run_anomalies.project_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = agent_run_anomalies.project_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."agent_run_logs";
        CREATE POLICY "tenant_isolation" ON "public"."agent_run_logs" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM (agent_runs
             JOIN projects ON ((projects.id = agent_runs.project_id)))
          WHERE ((agent_runs.id = agent_run_logs.agent_run_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM (agent_runs
             JOIN projects ON ((projects.id = agent_runs.project_id)))
          WHERE ((agent_runs.id = agent_run_logs.agent_run_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."agent_run_phases";
        CREATE POLICY "tenant_isolation" ON "public"."agent_run_phases" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM (agent_runs
             JOIN projects ON ((projects.id = agent_runs.project_id)))
          WHERE ((agent_runs.id = agent_run_phases.agent_run_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM (agent_runs
             JOIN projects ON ((projects.id = agent_runs.project_id)))
          WHERE ((agent_runs.id = agent_run_phases.agent_run_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."agent_run_resource_profiles";
        CREATE POLICY "tenant_isolation" ON "public"."agent_run_resource_profiles" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND ((project_id IS NULL) OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = agent_run_resource_profiles.project_id) AND (projects.account_id = paid_current_account_id()))))))))
          WITH CHECK ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND ((project_id IS NULL) OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = agent_run_resource_profiles.project_id) AND (projects.account_id = paid_current_account_id()))))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."agent_run_session_summaries";
        CREATE POLICY "tenant_isolation" ON "public"."agent_run_session_summaries" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = agent_run_session_summaries.project_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = agent_run_session_summaries.project_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."agent_runs";
        CREATE POLICY "tenant_isolation" ON "public"."agent_runs" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = agent_runs.project_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = agent_runs.project_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."api_usage_attempts";
        CREATE POLICY "tenant_isolation" ON "public"."api_usage_attempts" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (account_id = paid_current_account_id())))
          WITH CHECK ((paid_tenant_bypass() OR (account_id = paid_current_account_id())));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."apple_verification_artifacts";
        CREATE POLICY "tenant_isolation" ON "public"."apple_verification_artifacts" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM apple_verification_attempts
          WHERE ((apple_verification_attempts.id = apple_verification_artifacts.apple_verification_attempt_id) AND (apple_verification_attempts.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM apple_verification_attempts
          WHERE ((apple_verification_attempts.id = apple_verification_artifacts.apple_verification_attempt_id) AND (apple_verification_attempts.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."apple_verification_attempts";
        CREATE POLICY "tenant_isolation" ON "public"."apple_verification_attempts" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = apple_verification_attempts.project_id) AND (projects.account_id = paid_current_account_id())))) AND (EXISTS ( SELECT 1
           FROM apple_verification_workflow_revisions
          WHERE ((apple_verification_workflow_revisions.id = apple_verification_attempts.apple_verification_workflow_revision_id) AND (apple_verification_workflow_revisions.account_id = paid_current_account_id()) AND (apple_verification_workflow_revisions.project_id = apple_verification_attempts.project_id) AND (apple_verification_workflow_revisions.apple_worker_profile_id = apple_verification_attempts.apple_worker_profile_id)))) AND ((agent_run_id IS NULL) OR (EXISTS ( SELECT 1
           FROM agent_runs
          WHERE ((agent_runs.id = apple_verification_attempts.agent_run_id) AND (agent_runs.project_id = apple_verification_attempts.project_id))))))))
          WITH CHECK ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = apple_verification_attempts.project_id) AND (projects.account_id = paid_current_account_id())))) AND (EXISTS ( SELECT 1
           FROM apple_verification_workflow_revisions
          WHERE ((apple_verification_workflow_revisions.id = apple_verification_attempts.apple_verification_workflow_revision_id) AND (apple_verification_workflow_revisions.account_id = paid_current_account_id()) AND (apple_verification_workflow_revisions.project_id = apple_verification_attempts.project_id) AND (apple_verification_workflow_revisions.apple_worker_profile_id = apple_verification_attempts.apple_worker_profile_id)))) AND ((agent_run_id IS NULL) OR (EXISTS ( SELECT 1
           FROM agent_runs
          WHERE ((agent_runs.id = apple_verification_attempts.agent_run_id) AND (agent_runs.project_id = apple_verification_attempts.project_id))))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."apple_verification_images";
        CREATE POLICY "tenant_isolation" ON "public"."apple_verification_images" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (account_id = paid_current_account_id())))
          WITH CHECK ((paid_tenant_bypass() OR (account_id = paid_current_account_id())));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."apple_verification_waivers";
        CREATE POLICY "tenant_isolation" ON "public"."apple_verification_waivers" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = apple_verification_waivers.project_id) AND (projects.account_id = paid_current_account_id())))) AND (EXISTS ( SELECT 1
           FROM apple_verification_attempts
          WHERE ((apple_verification_attempts.id = apple_verification_waivers.apple_verification_attempt_id) AND (apple_verification_attempts.account_id = paid_current_account_id()) AND (apple_verification_attempts.project_id = apple_verification_waivers.project_id) AND (apple_verification_attempts.apple_verification_workflow_revision_id = apple_verification_waivers.apple_verification_workflow_revision_id)))) AND (EXISTS ( SELECT 1
           FROM users
          WHERE ((users.id = apple_verification_waivers.created_by_id) AND (users.account_id = paid_current_account_id())))))))
          WITH CHECK ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = apple_verification_waivers.project_id) AND (projects.account_id = paid_current_account_id())))) AND (EXISTS ( SELECT 1
           FROM apple_verification_attempts
          WHERE ((apple_verification_attempts.id = apple_verification_waivers.apple_verification_attempt_id) AND (apple_verification_attempts.account_id = paid_current_account_id()) AND (apple_verification_attempts.project_id = apple_verification_waivers.project_id) AND (apple_verification_attempts.apple_verification_workflow_revision_id = apple_verification_waivers.apple_verification_workflow_revision_id)))) AND (EXISTS ( SELECT 1
           FROM users
          WHERE ((users.id = apple_verification_waivers.created_by_id) AND (users.account_id = paid_current_account_id())))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."apple_verification_worker_healths";
        CREATE POLICY "tenant_isolation" ON "public"."apple_verification_worker_healths" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM apple_worker_profiles
          WHERE ((apple_worker_profiles.id = apple_verification_worker_healths.apple_worker_profile_id) AND (apple_worker_profiles.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM apple_worker_profiles
          WHERE ((apple_worker_profiles.id = apple_verification_worker_healths.apple_worker_profile_id) AND (apple_worker_profiles.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."apple_verification_workflow_revisions";
        CREATE POLICY "tenant_isolation" ON "public"."apple_verification_workflow_revisions" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = apple_verification_workflow_revisions.project_id) AND (projects.account_id = paid_current_account_id())))) AND (EXISTS ( SELECT 1
           FROM apple_worker_profiles
          WHERE ((apple_worker_profiles.id = apple_verification_workflow_revisions.apple_worker_profile_id) AND (apple_worker_profiles.account_id = paid_current_account_id())))) AND ((approved_by_id IS NULL) OR (EXISTS ( SELECT 1
           FROM users
          WHERE ((users.id = apple_verification_workflow_revisions.approved_by_id) AND (users.account_id = paid_current_account_id()))))))))
          WITH CHECK ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = apple_verification_workflow_revisions.project_id) AND (projects.account_id = paid_current_account_id())))) AND (EXISTS ( SELECT 1
           FROM apple_worker_profiles
          WHERE ((apple_worker_profiles.id = apple_verification_workflow_revisions.apple_worker_profile_id) AND (apple_worker_profiles.account_id = paid_current_account_id())))) AND ((approved_by_id IS NULL) OR (EXISTS ( SELECT 1
           FROM users
          WHERE ((users.id = apple_verification_workflow_revisions.approved_by_id) AND (users.account_id = paid_current_account_id()))))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."apple_worker_profiles";
        CREATE POLICY "tenant_isolation" ON "public"."apple_worker_profiles" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND ((created_by_id IS NULL) OR (EXISTS ( SELECT 1
           FROM users
          WHERE ((users.id = apple_worker_profiles.created_by_id) AND (users.account_id = paid_current_account_id()))))))))
          WITH CHECK ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND ((created_by_id IS NULL) OR (EXISTS ( SELECT 1
           FROM users
          WHERE ((users.id = apple_worker_profiles.created_by_id) AND (users.account_id = paid_current_account_id()))))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."auto_merge_attempts";
        CREATE POLICY "tenant_isolation" ON "public"."auto_merge_attempts" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = auto_merge_attempts.project_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = auto_merge_attempts.project_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."billing_invoices";
        CREATE POLICY "tenant_isolation" ON "public"."billing_invoices" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND (EXISTS ( SELECT 1
           FROM billing_periods
          WHERE ((billing_periods.id = billing_invoices.billing_period_id) AND (billing_periods.account_id = paid_current_account_id())))))))
          WITH CHECK ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND (EXISTS ( SELECT 1
           FROM billing_periods
          WHERE ((billing_periods.id = billing_invoices.billing_period_id) AND (billing_periods.account_id = paid_current_account_id())))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."billing_line_items";
        CREATE POLICY "tenant_isolation" ON "public"."billing_line_items" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM billing_invoices
          WHERE ((billing_invoices.id = billing_line_items.billing_invoice_id) AND (billing_invoices.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM billing_invoices
          WHERE ((billing_invoices.id = billing_line_items.billing_invoice_id) AND (billing_invoices.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."billing_periods";
        CREATE POLICY "tenant_isolation" ON "public"."billing_periods" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND (EXISTS ( SELECT 1
           FROM billing_plans
          WHERE ((billing_plans.id = billing_periods.billing_plan_id) AND (billing_plans.account_id = paid_current_account_id())))))))
          WITH CHECK ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND (EXISTS ( SELECT 1
           FROM billing_plans
          WHERE ((billing_plans.id = billing_periods.billing_plan_id) AND (billing_plans.account_id = paid_current_account_id())))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."billing_plans";
        CREATE POLICY "tenant_isolation" ON "public"."billing_plans" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (account_id = paid_current_account_id())))
          WITH CHECK ((paid_tenant_bypass() OR (account_id = paid_current_account_id())));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."bounded_delegated_actions";
        CREATE POLICY "tenant_isolation" ON "public"."bounded_delegated_actions" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = bounded_delegated_actions.project_id) AND (projects.account_id = paid_current_account_id())))) AND (EXISTS ( SELECT 1
           FROM (issues
             JOIN projects issue_projects ON ((issue_projects.id = issues.project_id)))
          WHERE ((issues.id = bounded_delegated_actions.issue_id) AND (issues.project_id = bounded_delegated_actions.project_id) AND (issue_projects.account_id = paid_current_account_id())))) AND ((created_by_id IS NULL) OR (EXISTS ( SELECT 1
           FROM users
          WHERE ((users.id = bounded_delegated_actions.created_by_id) AND (users.account_id = paid_current_account_id()))))) AND ((revoked_by_id IS NULL) OR (EXISTS ( SELECT 1
           FROM users
          WHERE ((users.id = bounded_delegated_actions.revoked_by_id) AND (users.account_id = paid_current_account_id()))))))))
          WITH CHECK ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = bounded_delegated_actions.project_id) AND (projects.account_id = paid_current_account_id())))) AND (EXISTS ( SELECT 1
           FROM (issues
             JOIN projects issue_projects ON ((issue_projects.id = issues.project_id)))
          WHERE ((issues.id = bounded_delegated_actions.issue_id) AND (issues.project_id = bounded_delegated_actions.project_id) AND (issue_projects.account_id = paid_current_account_id())))) AND ((created_by_id IS NULL) OR (EXISTS ( SELECT 1
           FROM users
          WHERE ((users.id = bounded_delegated_actions.created_by_id) AND (users.account_id = paid_current_account_id()))))) AND ((revoked_by_id IS NULL) OR (EXISTS ( SELECT 1
           FROM users
          WHERE ((users.id = bounded_delegated_actions.revoked_by_id) AND (users.account_id = paid_current_account_id()))))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."bundle_outcomes";
        CREATE POLICY "tenant_isolation" ON "public"."bundle_outcomes" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR ((EXISTS ( SELECT 1
           FROM configuration_bundles
          WHERE ((configuration_bundles.id = bundle_outcomes.configuration_bundle_id) AND (configuration_bundles.account_id = paid_current_account_id())))) AND (EXISTS ( SELECT 1
           FROM (agent_runs
             JOIN projects ON ((projects.id = agent_runs.project_id)))
          WHERE ((agent_runs.id = bundle_outcomes.agent_run_id) AND (projects.account_id = paid_current_account_id())))))))
          WITH CHECK ((paid_tenant_bypass() OR ((EXISTS ( SELECT 1
           FROM configuration_bundles
          WHERE ((configuration_bundles.id = bundle_outcomes.configuration_bundle_id) AND (configuration_bundles.account_id = paid_current_account_id())))) AND (EXISTS ( SELECT 1
           FROM (agent_runs
             JOIN projects ON ((projects.id = agent_runs.project_id)))
          WHERE ((agent_runs.id = bundle_outcomes.agent_run_id) AND (projects.account_id = paid_current_account_id())))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."change_intents";
        CREATE POLICY "tenant_isolation" ON "public"."change_intents" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = change_intents.project_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = change_intents.project_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."chat_diagram_comments";
        CREATE POLICY "tenant_isolation" ON "public"."chat_diagram_comments" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR ((EXISTS ( SELECT 1
           FROM (chat_diagrams
             JOIN chat_sessions ON ((chat_sessions.id = chat_diagrams.chat_session_id)))
          WHERE ((chat_diagrams.id = chat_diagram_comments.chat_diagram_id) AND (chat_sessions.account_id = paid_current_account_id())))) AND (EXISTS ( SELECT 1
           FROM users
          WHERE ((users.id = chat_diagram_comments.actor_id) AND (users.account_id = paid_current_account_id())))))))
          WITH CHECK ((paid_tenant_bypass() OR ((EXISTS ( SELECT 1
           FROM (chat_diagrams
             JOIN chat_sessions ON ((chat_sessions.id = chat_diagrams.chat_session_id)))
          WHERE ((chat_diagrams.id = chat_diagram_comments.chat_diagram_id) AND (chat_sessions.account_id = paid_current_account_id())))) AND (EXISTS ( SELECT 1
           FROM users
          WHERE ((users.id = chat_diagram_comments.actor_id) AND (users.account_id = paid_current_account_id())))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."chat_diagrams";
        CREATE POLICY "tenant_isolation" ON "public"."chat_diagrams" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM chat_sessions
          WHERE ((chat_sessions.id = chat_diagrams.chat_session_id) AND (chat_sessions.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM chat_sessions
          WHERE ((chat_sessions.id = chat_diagrams.chat_session_id) AND (chat_sessions.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."chat_investigations";
        CREATE POLICY "tenant_isolation" ON "public"."chat_investigations" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = chat_investigations.project_id) AND (projects.account_id = paid_current_account_id())))) AND (EXISTS ( SELECT 1
           FROM chat_sessions
          WHERE ((chat_sessions.id = chat_investigations.chat_session_id) AND (chat_sessions.account_id = paid_current_account_id())))) AND (EXISTS ( SELECT 1
           FROM clarifying_question_progresses
          WHERE ((clarifying_question_progresses.id = chat_investigations.clarifying_question_progress_id) AND (clarifying_question_progresses.account_id = paid_current_account_id())))) AND (EXISTS ( SELECT 1
           FROM users
          WHERE ((users.id = chat_investigations.created_by_id) AND (users.account_id = paid_current_account_id())))))))
          WITH CHECK ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = chat_investigations.project_id) AND (projects.account_id = paid_current_account_id())))) AND (EXISTS ( SELECT 1
           FROM chat_sessions
          WHERE ((chat_sessions.id = chat_investigations.chat_session_id) AND (chat_sessions.account_id = paid_current_account_id())))) AND (EXISTS ( SELECT 1
           FROM clarifying_question_progresses
          WHERE ((clarifying_question_progresses.id = chat_investigations.clarifying_question_progress_id) AND (clarifying_question_progresses.account_id = paid_current_account_id())))) AND (EXISTS ( SELECT 1
           FROM users
          WHERE ((users.id = chat_investigations.created_by_id) AND (users.account_id = paid_current_account_id())))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."chat_messages";
        CREATE POLICY "tenant_isolation" ON "public"."chat_messages" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM chat_sessions
          WHERE ((chat_sessions.id = chat_messages.chat_session_id) AND (chat_sessions.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM chat_sessions
          WHERE ((chat_sessions.id = chat_messages.chat_session_id) AND (chat_sessions.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."chat_session_projects";
        CREATE POLICY "tenant_isolation" ON "public"."chat_session_projects" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR ((EXISTS ( SELECT 1
           FROM chat_sessions
          WHERE ((chat_sessions.id = chat_session_projects.chat_session_id) AND (chat_sessions.account_id = paid_current_account_id())))) AND (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = chat_session_projects.project_id) AND (projects.account_id = paid_current_account_id())))))))
          WITH CHECK ((paid_tenant_bypass() OR ((EXISTS ( SELECT 1
           FROM chat_sessions
          WHERE ((chat_sessions.id = chat_session_projects.chat_session_id) AND (chat_sessions.account_id = paid_current_account_id())))) AND (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = chat_session_projects.project_id) AND (projects.account_id = paid_current_account_id())))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."chat_sessions";
        CREATE POLICY "tenant_isolation" ON "public"."chat_sessions" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND ((project_id IS NULL) OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = chat_sessions.project_id) AND (projects.account_id = paid_current_account_id()))))) AND ((runner_id IS NULL) OR (EXISTS ( SELECT 1
           FROM runners
          WHERE ((runners.id = chat_sessions.runner_id) AND (runners.user_id IN ( SELECT users.id
                   FROM users
                  WHERE (users.account_id = paid_current_account_id()))))))) AND ((created_by_id IS NULL) OR (EXISTS ( SELECT 1
           FROM users
          WHERE ((users.id = chat_sessions.created_by_id) AND (users.account_id = paid_current_account_id()))))))))
          WITH CHECK ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND ((project_id IS NULL) OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = chat_sessions.project_id) AND (projects.account_id = paid_current_account_id()))))) AND ((runner_id IS NULL) OR (EXISTS ( SELECT 1
           FROM runners
          WHERE ((runners.id = chat_sessions.runner_id) AND (runners.user_id IN ( SELECT users.id
                   FROM users
                  WHERE (users.account_id = paid_current_account_id()))))))) AND ((created_by_id IS NULL) OR (EXISTS ( SELECT 1
           FROM users
          WHERE ((users.id = chat_sessions.created_by_id) AND (users.account_id = paid_current_account_id()))))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."chat_turn_lifecycle_events";
        CREATE POLICY "tenant_isolation" ON "public"."chat_turn_lifecycle_events" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM chat_sessions
          WHERE ((chat_sessions.id = chat_turn_lifecycle_events.chat_session_id) AND (chat_sessions.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM chat_sessions
          WHERE ((chat_sessions.id = chat_turn_lifecycle_events.chat_session_id) AND (chat_sessions.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."chat_turns";
        CREATE POLICY "tenant_isolation" ON "public"."chat_turns" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM chat_sessions
          WHERE ((chat_sessions.id = chat_turns.chat_session_id) AND (chat_sessions.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM chat_sessions
          WHERE ((chat_sessions.id = chat_turns.chat_session_id) AND (chat_sessions.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."clarifying_question_progresses";
        CREATE POLICY "tenant_isolation" ON "public"."clarifying_question_progresses" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (account_id = paid_current_account_id())))
          WITH CHECK ((paid_tenant_bypass() OR (account_id = paid_current_account_id())));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."collector_runs";
        CREATE POLICY "tenant_isolation" ON "public"."collector_runs" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM (project_versions
             JOIN projects ON ((projects.id = project_versions.project_id)))
          WHERE ((project_versions.id = collector_runs.project_version_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM (project_versions
             JOIN projects ON ((projects.id = project_versions.project_id)))
          WHERE ((project_versions.id = collector_runs.project_version_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."configuration_bundles";
        CREATE POLICY "tenant_isolation" ON "public"."configuration_bundles" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND ((project_id IS NULL) OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = configuration_bundles.project_id) AND (projects.account_id = paid_current_account_id()))))))))
          WITH CHECK ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND ((project_id IS NULL) OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = configuration_bundles.project_id) AND (projects.account_id = paid_current_account_id()))))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."configuration_experiments";
        CREATE POLICY "tenant_isolation" ON "public"."configuration_experiments" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (account_id = paid_current_account_id())))
          WITH CHECK ((paid_tenant_bypass() OR (account_id = paid_current_account_id())));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."container_metrics";
        CREATE POLICY "tenant_isolation" ON "public"."container_metrics" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM (agent_runs
             JOIN projects ON ((projects.id = agent_runs.project_id)))
          WHERE ((agent_runs.id = container_metrics.agent_run_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM (agent_runs
             JOIN projects ON ((projects.id = agent_runs.project_id)))
          WHERE ((agent_runs.id = container_metrics.agent_run_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."container_pool_entries";
        CREATE POLICY "tenant_isolation" ON "public"."container_pool_entries" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = container_pool_entries.project_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = container_pool_entries.project_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."context_intake_questions";
        CREATE POLICY "tenant_isolation" ON "public"."context_intake_questions" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = context_intake_questions.project_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = context_intake_questions.project_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."context_intake_responses";
        CREATE POLICY "tenant_isolation" ON "public"."context_intake_responses" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM (context_intake_sessions
             JOIN projects ON ((projects.id = context_intake_sessions.project_id)))
          WHERE ((context_intake_sessions.id = context_intake_responses.context_intake_session_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM (context_intake_sessions
             JOIN projects ON ((projects.id = context_intake_sessions.project_id)))
          WHERE ((context_intake_sessions.id = context_intake_responses.context_intake_session_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."context_intake_sessions";
        CREATE POLICY "tenant_isolation" ON "public"."context_intake_sessions" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = context_intake_sessions.project_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = context_intake_sessions.project_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."coordination_experiment_assignments";
        CREATE POLICY "tenant_isolation" ON "public"."coordination_experiment_assignments" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = coordination_experiment_assignments.project_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = coordination_experiment_assignments.project_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."coordination_experiments";
        CREATE POLICY "tenant_isolation" ON "public"."coordination_experiments" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (account_id = paid_current_account_id())))
          WITH CHECK ((paid_tenant_bypass() OR (account_id = paid_current_account_id())));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."coordination_policies";
        CREATE POLICY "tenant_isolation" ON "public"."coordination_policies" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND ((project_id IS NULL) OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = coordination_policies.project_id) AND (projects.account_id = paid_current_account_id()))))))))
          WITH CHECK ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND ((project_id IS NULL) OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = coordination_policies.project_id) AND (projects.account_id = paid_current_account_id()))))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."coordination_policy_versions";
        CREATE POLICY "tenant_isolation" ON "public"."coordination_policy_versions" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM coordination_policies
          WHERE ((coordination_policies.id = coordination_policy_versions.coordination_policy_id) AND (coordination_policies.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM coordination_policies
          WHERE ((coordination_policies.id = coordination_policy_versions.coordination_policy_id) AND (coordination_policies.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."cost_budgets";
        CREATE POLICY "tenant_isolation" ON "public"."cost_budgets" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = cost_budgets.project_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = cost_budgets.project_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."decision_record_links";
        CREATE POLICY "tenant_isolation" ON "public"."decision_record_links" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM (decision_records
             JOIN projects ON ((projects.id = decision_records.project_id)))
          WHERE ((decision_records.id = decision_record_links.decision_record_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM (decision_records
             JOIN projects ON ((projects.id = decision_records.project_id)))
          WHERE ((decision_records.id = decision_record_links.decision_record_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."decision_records";
        CREATE POLICY "tenant_isolation" ON "public"."decision_records" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = decision_records.project_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = decision_records.project_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."decomposition_decisions";
        CREATE POLICY "tenant_isolation" ON "public"."decomposition_decisions" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = decomposition_decisions.project_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = decomposition_decisions.project_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."dependabot_alert_coverages";
        CREATE POLICY "tenant_isolation" ON "public"."dependabot_alert_coverages" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (account_id = paid_current_account_id())))
          WITH CHECK ((paid_tenant_bypass() OR (account_id = paid_current_account_id())));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."design_amendment_follow_ups";
        CREATE POLICY "tenant_isolation" ON "public"."design_amendment_follow_ups" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM (design_amendments
             JOIN projects ON ((projects.id = design_amendments.project_id)))
          WHERE ((design_amendments.id = design_amendment_follow_ups.design_amendment_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM (design_amendments
             JOIN projects ON ((projects.id = design_amendments.project_id)))
          WHERE ((design_amendments.id = design_amendment_follow_ups.design_amendment_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."design_amendment_pauses";
        CREATE POLICY "tenant_isolation" ON "public"."design_amendment_pauses" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM (design_amendments
             JOIN projects ON ((projects.id = design_amendments.project_id)))
          WHERE ((design_amendments.id = design_amendment_pauses.design_amendment_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM (design_amendments
             JOIN projects ON ((projects.id = design_amendments.project_id)))
          WHERE ((design_amendments.id = design_amendment_pauses.design_amendment_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."design_amendments";
        CREATE POLICY "tenant_isolation" ON "public"."design_amendments" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = design_amendments.project_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = design_amendments.project_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."design_artifact_associations";
        CREATE POLICY "tenant_isolation" ON "public"."design_artifact_associations" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (account_id = paid_current_account_id())))
          WITH CHECK ((paid_tenant_bypass() OR (account_id = paid_current_account_id())));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."design_artifact_findings";
        CREATE POLICY "tenant_isolation" ON "public"."design_artifact_findings" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (account_id = paid_current_account_id())))
          WITH CHECK ((paid_tenant_bypass() OR (account_id = paid_current_account_id())));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."dispatch_circuit_breakers";
        CREATE POLICY "tenant_isolation" ON "public"."dispatch_circuit_breakers" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (account_id = paid_current_account_id())))
          WITH CHECK ((paid_tenant_bypass() OR (account_id = paid_current_account_id())));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."docker_hosts";
        CREATE POLICY "tenant_isolation" ON "public"."docker_hosts" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (account_id = paid_current_account_id())))
          WITH CHECK ((paid_tenant_bypass() OR (account_id = paid_current_account_id())));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."egress_allowlist_entries";
        CREATE POLICY "tenant_isolation" ON "public"."egress_allowlist_entries" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (account_id = paid_current_account_id())))
          WITH CHECK ((paid_tenant_bypass() OR (account_id = paid_current_account_id())));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."egress_security_events";
        CREATE POLICY "tenant_isolation" ON "public"."egress_security_events" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (account_id = paid_current_account_id())))
          WITH CHECK ((paid_tenant_bypass() OR (account_id = paid_current_account_id())));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."exception_incidents";
        CREATE POLICY "tenant_isolation" ON "public"."exception_incidents" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (account_id = paid_current_account_id())))
          WITH CHECK ((paid_tenant_bypass() OR (account_id = paid_current_account_id())));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."execution_audit_events";
        CREATE POLICY "tenant_isolation" ON "public"."execution_audit_events" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (account_id = paid_current_account_id())))
          WITH CHECK ((paid_tenant_bypass() OR (account_id = paid_current_account_id())));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."execution_controls";
        CREATE POLICY "tenant_isolation" ON "public"."execution_controls" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (((scope)::text <> 'global'::text) AND ((account_id = paid_current_account_id()) OR ((account_id IS NULL) AND (project_id IS NOT NULL) AND (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = execution_controls.project_id) AND (projects.account_id = paid_current_account_id()))))) OR ((account_id IS NULL) AND (runner_id IS NOT NULL) AND (EXISTS ( SELECT 1
           FROM (runners
             JOIN users ON ((users.id = runners.user_id)))
          WHERE ((runners.id = execution_controls.runner_id) AND (users.account_id = paid_current_account_id()))))) OR ((account_id IS NULL) AND (docker_host_id IS NOT NULL) AND (EXISTS ( SELECT 1
           FROM docker_hosts
          WHERE ((docker_hosts.id = execution_controls.docker_host_id) AND (docker_hosts.account_id = paid_current_account_id())))))))))
          WITH CHECK ((paid_tenant_bypass() OR (((scope)::text <> 'global'::text) AND ((account_id = paid_current_account_id()) OR ((account_id IS NULL) AND (project_id IS NOT NULL) AND (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = execution_controls.project_id) AND (projects.account_id = paid_current_account_id()))))) OR ((account_id IS NULL) AND (runner_id IS NOT NULL) AND (EXISTS ( SELECT 1
           FROM (runners
             JOIN users ON ((users.id = runners.user_id)))
          WHERE ((runners.id = execution_controls.runner_id) AND (users.account_id = paid_current_account_id()))))) OR ((account_id IS NULL) AND (docker_host_id IS NOT NULL) AND (EXISTS ( SELECT 1
           FROM docker_hosts
          WHERE ((docker_hosts.id = execution_controls.docker_host_id) AND (docker_hosts.account_id = paid_current_account_id())))))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."execution_resource_ledger_entries";
        CREATE POLICY "tenant_isolation" ON "public"."execution_resource_ledger_entries" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (account_id = paid_current_account_id())))
          WITH CHECK ((paid_tenant_bypass() OR (account_id = paid_current_account_id())));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."execution_resources";
        CREATE POLICY "tenant_isolation" ON "public"."execution_resources" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR ((account_id IS NULL) OR (account_id = paid_current_account_id()))))
          WITH CHECK ((paid_tenant_bypass() OR ((account_id IS NULL) OR (account_id = paid_current_account_id()))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."execution_usages";
        CREATE POLICY "tenant_isolation" ON "public"."execution_usages" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM (agent_runs
             JOIN projects ON ((projects.id = agent_runs.project_id)))
          WHERE ((agent_runs.id = execution_usages.agent_run_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM (agent_runs
             JOIN projects ON ((projects.id = agent_runs.project_id)))
          WHERE ((agent_runs.id = execution_usages.agent_run_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."explicit_preferences";
        CREATE POLICY "tenant_isolation" ON "public"."explicit_preferences" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (account_id = paid_current_account_id())))
          WITH CHECK ((paid_tenant_bypass() OR (account_id = paid_current_account_id())));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."external_connector_events";
        CREATE POLICY "tenant_isolation" ON "public"."external_connector_events" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND ((project_id IS NULL) OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = external_connector_events.project_id) AND (projects.account_id = paid_current_account_id()))))))))
          WITH CHECK ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND ((project_id IS NULL) OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = external_connector_events.project_id) AND (projects.account_id = paid_current_account_id()))))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."facet_confidence_evaluation_label_revisions";
        CREATE POLICY "tenant_isolation" ON "public"."facet_confidence_evaluation_label_revisions" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM ((facet_confidence_evaluation_labels labels
             JOIN facet_confidence_evaluations evaluations ON ((evaluations.id = labels.facet_confidence_evaluation_id)))
             JOIN projects ON ((projects.id = evaluations.project_id)))
          WHERE ((labels.id = facet_confidence_evaluation_label_revisions.facet_confidence_evaluation_label_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM ((facet_confidence_evaluation_labels labels
             JOIN facet_confidence_evaluations evaluations ON ((evaluations.id = labels.facet_confidence_evaluation_id)))
             JOIN projects ON ((projects.id = evaluations.project_id)))
          WHERE ((labels.id = facet_confidence_evaluation_label_revisions.facet_confidence_evaluation_label_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."facet_confidence_evaluation_labels";
        CREATE POLICY "tenant_isolation" ON "public"."facet_confidence_evaluation_labels" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM (facet_confidence_evaluations e
             JOIN projects ON ((projects.id = e.project_id)))
          WHERE ((e.id = facet_confidence_evaluation_labels.facet_confidence_evaluation_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM (facet_confidence_evaluations e
             JOIN projects ON ((projects.id = e.project_id)))
          WHERE ((e.id = facet_confidence_evaluation_labels.facet_confidence_evaluation_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."facet_confidence_evaluations";
        CREATE POLICY "tenant_isolation" ON "public"."facet_confidence_evaluations" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = facet_confidence_evaluations.project_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = facet_confidence_evaluations.project_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."failure_classifications";
        CREATE POLICY "tenant_isolation" ON "public"."failure_classifications" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = failure_classifications.project_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = failure_classifications.project_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."feature_intent_approval_revisions";
        CREATE POLICY "tenant_isolation" ON "public"."feature_intent_approval_revisions" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM (feature_intents
             JOIN projects ON ((projects.id = feature_intents.project_id)))
          WHERE ((feature_intents.id = feature_intent_approval_revisions.feature_intent_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM (feature_intents
             JOIN projects ON ((projects.id = feature_intents.project_id)))
          WHERE ((feature_intents.id = feature_intent_approval_revisions.feature_intent_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."feature_intent_completions";
        CREATE POLICY "tenant_isolation" ON "public"."feature_intent_completions" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM (feature_intents
             JOIN projects ON ((projects.id = feature_intents.project_id)))
          WHERE ((feature_intents.id = feature_intent_completions.feature_intent_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM (feature_intents
             JOIN projects ON ((projects.id = feature_intents.project_id)))
          WHERE ((feature_intents.id = feature_intent_completions.feature_intent_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."feature_intent_decisions";
        CREATE POLICY "tenant_isolation" ON "public"."feature_intent_decisions" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM (feature_intents
             JOIN projects ON ((projects.id = feature_intents.project_id)))
          WHERE ((feature_intents.id = feature_intent_decisions.feature_intent_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM (feature_intents
             JOIN projects ON ((projects.id = feature_intents.project_id)))
          WHERE ((feature_intents.id = feature_intent_decisions.feature_intent_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."feature_intent_design_prs";
        CREATE POLICY "tenant_isolation" ON "public"."feature_intent_design_prs" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM (feature_intents
             JOIN projects ON ((projects.id = feature_intents.project_id)))
          WHERE ((feature_intents.id = feature_intent_design_prs.feature_intent_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM (feature_intents
             JOIN projects ON ((projects.id = feature_intents.project_id)))
          WHERE ((feature_intents.id = feature_intent_design_prs.feature_intent_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."feature_intent_facet_assessments";
        CREATE POLICY "tenant_isolation" ON "public"."feature_intent_facet_assessments" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (account_id = paid_current_account_id())))
          WITH CHECK ((paid_tenant_bypass() OR (account_id = paid_current_account_id())));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."feature_intent_facet_directions";
        CREATE POLICY "tenant_isolation" ON "public"."feature_intent_facet_directions" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (account_id = paid_current_account_id())))
          WITH CHECK ((paid_tenant_bypass() OR (account_id = paid_current_account_id())));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."feature_intent_facet_evidence";
        CREATE POLICY "tenant_isolation" ON "public"."feature_intent_facet_evidence" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (account_id = paid_current_account_id())))
          WITH CHECK ((paid_tenant_bypass() OR (account_id = paid_current_account_id())));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."feature_intent_facets";
        CREATE POLICY "tenant_isolation" ON "public"."feature_intent_facets" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (account_id = paid_current_account_id())))
          WITH CHECK ((paid_tenant_bypass() OR (account_id = paid_current_account_id())));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."feature_intent_forward_work_items";
        CREATE POLICY "tenant_isolation" ON "public"."feature_intent_forward_work_items" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM ((feature_intent_completions
             JOIN feature_intents ON ((feature_intents.id = feature_intent_completions.feature_intent_id)))
             JOIN projects ON ((projects.id = feature_intents.project_id)))
          WHERE ((feature_intent_completions.id = feature_intent_forward_work_items.feature_intent_completion_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM ((feature_intent_completions
             JOIN feature_intents ON ((feature_intents.id = feature_intent_completions.feature_intent_id)))
             JOIN projects ON ((projects.id = feature_intents.project_id)))
          WHERE ((feature_intent_completions.id = feature_intent_forward_work_items.feature_intent_completion_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."feature_intent_issue_dependencies";
        CREATE POLICY "tenant_isolation" ON "public"."feature_intent_issue_dependencies" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM ((feature_intent_issues
             JOIN feature_intents ON ((feature_intents.id = feature_intent_issues.feature_intent_id)))
             JOIN projects ON ((projects.id = feature_intents.project_id)))
          WHERE ((feature_intent_issues.id = feature_intent_issue_dependencies.feature_intent_issue_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM ((feature_intent_issues
             JOIN feature_intents ON ((feature_intents.id = feature_intent_issues.feature_intent_id)))
             JOIN projects ON ((projects.id = feature_intents.project_id)))
          WHERE ((feature_intent_issues.id = feature_intent_issue_dependencies.feature_intent_issue_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."feature_intent_issue_prerequisite_mappings";
        CREATE POLICY "tenant_isolation" ON "public"."feature_intent_issue_prerequisite_mappings" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (account_id = paid_current_account_id())))
          WITH CHECK ((paid_tenant_bypass() OR (account_id = paid_current_account_id())));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."feature_intent_issue_prerequisites";
        CREATE POLICY "tenant_isolation" ON "public"."feature_intent_issue_prerequisites" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (account_id = paid_current_account_id())))
          WITH CHECK ((paid_tenant_bypass() OR (account_id = paid_current_account_id())));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."feature_intent_issues";
        CREATE POLICY "tenant_isolation" ON "public"."feature_intent_issues" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM (feature_intents
             JOIN projects ON ((projects.id = feature_intents.project_id)))
          WHERE ((feature_intents.id = feature_intent_issues.feature_intent_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM (feature_intents
             JOIN projects ON ((projects.id = feature_intents.project_id)))
          WHERE ((feature_intents.id = feature_intent_issues.feature_intent_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."feature_intents";
        CREATE POLICY "tenant_isolation" ON "public"."feature_intents" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = feature_intents.project_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = feature_intents.project_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."github_installations";
        CREATE POLICY "tenant_isolation" ON "public"."github_installations" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (account_id = paid_current_account_id())))
          WITH CHECK ((paid_tenant_bypass() OR (account_id = paid_current_account_id())));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."github_tokens";
        CREATE POLICY "tenant_isolation" ON "public"."github_tokens" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND ((created_by_id IS NULL) OR (EXISTS ( SELECT 1
           FROM users
          WHERE ((users.id = github_tokens.created_by_id) AND (users.account_id = paid_current_account_id()))))))))
          WITH CHECK ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND ((created_by_id IS NULL) OR (EXISTS ( SELECT 1
           FROM users
          WHERE ((users.id = github_tokens.created_by_id) AND (users.account_id = paid_current_account_id()))))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."inbox_history_events";
        CREATE POLICY "tenant_isolation" ON "public"."inbox_history_events" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = inbox_history_events.project_id) AND (projects.account_id = paid_current_account_id())))))))
          WITH CHECK ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = inbox_history_events.project_id) AND (projects.account_id = paid_current_account_id())))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."integration_credentials";
        CREATE POLICY "tenant_isolation" ON "public"."integration_credentials" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND ((created_by_id IS NULL) OR (EXISTS ( SELECT 1
           FROM users
          WHERE ((users.id = integration_credentials.created_by_id) AND (users.account_id = paid_current_account_id()))))))))
          WITH CHECK ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND ((created_by_id IS NULL) OR (EXISTS ( SELECT 1
           FROM users
          WHERE ((users.id = integration_credentials.created_by_id) AND (users.account_id = paid_current_account_id()))))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."intent_conformance_decisions";
        CREATE POLICY "tenant_isolation" ON "public"."intent_conformance_decisions" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR ((EXISTS ( SELECT 1
           FROM (issues
             JOIN projects ON ((projects.id = issues.project_id)))
          WHERE ((issues.id = intent_conformance_decisions.issue_id) AND (projects.account_id = paid_current_account_id())))) AND (EXISTS ( SELECT 1
           FROM users
          WHERE ((users.id = intent_conformance_decisions.actor_id) AND (users.account_id = paid_current_account_id())))))))
          WITH CHECK ((paid_tenant_bypass() OR ((EXISTS ( SELECT 1
           FROM (issues
             JOIN projects ON ((projects.id = issues.project_id)))
          WHERE ((issues.id = intent_conformance_decisions.issue_id) AND (projects.account_id = paid_current_account_id())))) AND (EXISTS ( SELECT 1
           FROM users
          WHERE ((users.id = intent_conformance_decisions.actor_id) AND (users.account_id = paid_current_account_id())))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."intent_conformance_resolutions";
        CREATE POLICY "tenant_isolation" ON "public"."intent_conformance_resolutions" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = intent_conformance_resolutions.project_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = intent_conformance_resolutions.project_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."intent_conformance_review_schedules";
        CREATE POLICY "tenant_isolation" ON "public"."intent_conformance_review_schedules" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM (issues
             JOIN projects ON ((projects.id = issues.project_id)))
          WHERE ((issues.id = intent_conformance_review_schedules.issue_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM (issues
             JOIN projects ON ((projects.id = issues.project_id)))
          WHERE ((issues.id = intent_conformance_review_schedules.issue_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."intent_conformance_shadow_evaluation_labels";
        CREATE POLICY "tenant_isolation" ON "public"."intent_conformance_shadow_evaluation_labels" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM (intent_conformance_shadow_evaluations e
             JOIN projects ON ((projects.id = e.project_id)))
          WHERE ((e.id = intent_conformance_shadow_evaluation_labels.shadow_evaluation_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM (intent_conformance_shadow_evaluations e
             JOIN projects ON ((projects.id = e.project_id)))
          WHERE ((e.id = intent_conformance_shadow_evaluation_labels.shadow_evaluation_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."intent_conformance_shadow_evaluation_runs";
        CREATE POLICY "tenant_isolation" ON "public"."intent_conformance_shadow_evaluation_runs" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM (intent_conformance_shadow_evaluations e
             JOIN projects ON ((projects.id = e.project_id)))
          WHERE ((e.id = intent_conformance_shadow_evaluation_runs.shadow_evaluation_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM (intent_conformance_shadow_evaluations e
             JOIN projects ON ((projects.id = e.project_id)))
          WHERE ((e.id = intent_conformance_shadow_evaluation_runs.shadow_evaluation_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."intent_conformance_shadow_evaluations";
        CREATE POLICY "tenant_isolation" ON "public"."intent_conformance_shadow_evaluations" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = intent_conformance_shadow_evaluations.project_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = intent_conformance_shadow_evaluations.project_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."intent_conformance_verdicts";
        CREATE POLICY "tenant_isolation" ON "public"."intent_conformance_verdicts" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM (issues
             JOIN projects ON ((projects.id = issues.project_id)))
          WHERE ((issues.id = intent_conformance_verdicts.issue_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM (issues
             JOIN projects ON ((projects.id = issues.project_id)))
          WHERE ((issues.id = intent_conformance_verdicts.issue_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."issue_continuation_requests";
        CREATE POLICY "tenant_isolation" ON "public"."issue_continuation_requests" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM (issues
             JOIN projects ON ((projects.id = issues.project_id)))
          WHERE ((issues.id = issue_continuation_requests.issue_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM (issues
             JOIN projects ON ((projects.id = issues.project_id)))
          WHERE ((issues.id = issue_continuation_requests.issue_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."issue_dependencies";
        CREATE POLICY "tenant_isolation" ON "public"."issue_dependencies" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR ((EXISTS ( SELECT 1
           FROM (issues
             JOIN projects ON ((projects.id = issues.project_id)))
          WHERE ((issues.id = issue_dependencies.issue_id) AND (projects.account_id = paid_current_account_id())))) AND ((depends_on_issue_id IS NULL) OR (EXISTS ( SELECT 1
           FROM (issues depends_on_issues
             JOIN projects ON ((projects.id = depends_on_issues.project_id)))
          WHERE ((depends_on_issues.id = issue_dependencies.depends_on_issue_id) AND (projects.account_id = paid_current_account_id()))))))))
          WITH CHECK ((paid_tenant_bypass() OR ((EXISTS ( SELECT 1
           FROM (issues
             JOIN projects ON ((projects.id = issues.project_id)))
          WHERE ((issues.id = issue_dependencies.issue_id) AND (projects.account_id = paid_current_account_id())))) AND ((depends_on_issue_id IS NULL) OR (EXISTS ( SELECT 1
           FROM (issues depends_on_issues
             JOIN projects ON ((projects.id = depends_on_issues.project_id)))
          WHERE ((depends_on_issues.id = issue_dependencies.depends_on_issue_id) AND (projects.account_id = paid_current_account_id()))))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."issue_merge_subscriptions";
        CREATE POLICY "tenant_isolation" ON "public"."issue_merge_subscriptions" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR ((EXISTS ( SELECT 1
           FROM (issues
             JOIN projects ON ((projects.id = issues.project_id)))
          WHERE ((issues.id = issue_merge_subscriptions.issue_id) AND (projects.account_id = paid_current_account_id())))) AND (EXISTS ( SELECT 1
           FROM users
          WHERE ((users.id = issue_merge_subscriptions.user_id) AND (users.account_id = paid_current_account_id())))))))
          WITH CHECK ((paid_tenant_bypass() OR ((EXISTS ( SELECT 1
           FROM (issues
             JOIN projects ON ((projects.id = issues.project_id)))
          WHERE ((issues.id = issue_merge_subscriptions.issue_id) AND (projects.account_id = paid_current_account_id())))) AND (EXISTS ( SELECT 1
           FROM users
          WHERE ((users.id = issue_merge_subscriptions.user_id) AND (users.account_id = paid_current_account_id())))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."issues";
        CREATE POLICY "tenant_isolation" ON "public"."issues" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = issues.project_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = issues.project_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."knowledge_artifacts";
        CREATE POLICY "tenant_isolation" ON "public"."knowledge_artifacts" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = knowledge_artifacts.project_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = knowledge_artifacts.project_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."knowledge_audit_events";
        CREATE POLICY "tenant_isolation" ON "public"."knowledge_audit_events" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = knowledge_audit_events.project_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = knowledge_audit_events.project_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."knowledge_chunks";
        CREATE POLICY "tenant_isolation" ON "public"."knowledge_chunks" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = knowledge_chunks.project_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = knowledge_chunks.project_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."knowledge_links";
        CREATE POLICY "tenant_isolation" ON "public"."knowledge_links" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR ((EXISTS ( SELECT 1
           FROM (knowledge_chunks
             JOIN projects ON ((projects.id = knowledge_chunks.project_id)))
          WHERE ((knowledge_chunks.id = knowledge_links.source_chunk_id) AND (projects.account_id = paid_current_account_id())))) AND (EXISTS ( SELECT 1
           FROM (knowledge_chunks
             JOIN projects ON ((projects.id = knowledge_chunks.project_id)))
          WHERE ((knowledge_chunks.id = knowledge_links.target_chunk_id) AND (projects.account_id = paid_current_account_id())))))))
          WITH CHECK ((paid_tenant_bypass() OR ((EXISTS ( SELECT 1
           FROM (knowledge_chunks
             JOIN projects ON ((projects.id = knowledge_chunks.project_id)))
          WHERE ((knowledge_chunks.id = knowledge_links.source_chunk_id) AND (projects.account_id = paid_current_account_id())))) AND (EXISTS ( SELECT 1
           FROM (knowledge_chunks
             JOIN projects ON ((projects.id = knowledge_chunks.project_id)))
          WHERE ((knowledge_chunks.id = knowledge_links.target_chunk_id) AND (projects.account_id = paid_current_account_id())))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."knowledge_recommendations";
        CREATE POLICY "tenant_isolation" ON "public"."knowledge_recommendations" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = knowledge_recommendations.project_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = knowledge_recommendations.project_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."knowledge_runs";
        CREATE POLICY "tenant_isolation" ON "public"."knowledge_runs" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = knowledge_runs.project_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = knowledge_runs.project_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."knowledge_usage_stats";
        CREATE POLICY "tenant_isolation" ON "public"."knowledge_usage_stats" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = knowledge_usage_stats.project_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = knowledge_usage_stats.project_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."layered_verification_check_results";
        CREATE POLICY "tenant_isolation" ON "public"."layered_verification_check_results" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM (layered_verification_obligations o
             JOIN projects ON ((projects.id = o.project_id)))
          WHERE ((o.id = layered_verification_check_results.obligation_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM (layered_verification_obligations o
             JOIN projects ON ((projects.id = o.project_id)))
          WHERE ((o.id = layered_verification_check_results.obligation_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."layered_verification_correspondence_claims";
        CREATE POLICY "tenant_isolation" ON "public"."layered_verification_correspondence_claims" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM (layered_verification_obligations o
             JOIN projects ON ((projects.id = o.project_id)))
          WHERE ((o.id = layered_verification_correspondence_claims.obligation_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM (layered_verification_obligations o
             JOIN projects ON ((projects.id = o.project_id)))
          WHERE ((o.id = layered_verification_correspondence_claims.obligation_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."layered_verification_findings";
        CREATE POLICY "tenant_isolation" ON "public"."layered_verification_findings" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = layered_verification_findings.project_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = layered_verification_findings.project_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."layered_verification_obligations";
        CREATE POLICY "tenant_isolation" ON "public"."layered_verification_obligations" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = layered_verification_obligations.project_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = layered_verification_obligations.project_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."layered_verification_review_approvals";
        CREATE POLICY "tenant_isolation" ON "public"."layered_verification_review_approvals" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM (layered_verification_review_packages p
             JOIN projects ON ((projects.id = p.project_id)))
          WHERE ((p.id = layered_verification_review_approvals.package_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM (layered_verification_review_packages p
             JOIN projects ON ((projects.id = p.project_id)))
          WHERE ((p.id = layered_verification_review_approvals.package_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."layered_verification_review_packages";
        CREATE POLICY "tenant_isolation" ON "public"."layered_verification_review_packages" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = layered_verification_review_packages.project_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = layered_verification_review_packages.project_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."linear_tokens";
        CREATE POLICY "tenant_isolation" ON "public"."linear_tokens" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND ((created_by_id IS NULL) OR (EXISTS ( SELECT 1
           FROM users
          WHERE ((users.id = linear_tokens.created_by_id) AND (users.account_id = paid_current_account_id()))))))))
          WITH CHECK ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND ((created_by_id IS NULL) OR (EXISTS ( SELECT 1
           FROM users
          WHERE ((users.id = linear_tokens.created_by_id) AND (users.account_id = paid_current_account_id()))))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."llm_output_metrics";
        CREATE POLICY "tenant_isolation" ON "public"."llm_output_metrics" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (account_id = paid_current_account_id())))
          WITH CHECK ((paid_tenant_bypass() OR (account_id = paid_current_account_id())));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."maintenance_finding_occurrences";
        CREATE POLICY "tenant_isolation" ON "public"."maintenance_finding_occurrences" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (account_id = paid_current_account_id())))
          WITH CHECK ((paid_tenant_bypass() OR (account_id = paid_current_account_id())));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."maintenance_findings";
        CREATE POLICY "tenant_isolation" ON "public"."maintenance_findings" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (account_id = paid_current_account_id())))
          WITH CHECK ((paid_tenant_bypass() OR (account_id = paid_current_account_id())));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."maintenance_reports";
        CREATE POLICY "tenant_isolation" ON "public"."maintenance_reports" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (account_id = paid_current_account_id())))
          WITH CHECK ((paid_tenant_bypass() OR (account_id = paid_current_account_id())));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."marketplace_entries";
        CREATE POLICY "tenant_isolation" ON "public"."marketplace_entries" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (account_id = paid_current_account_id())))
          WITH CHECK ((paid_tenant_bypass() OR (account_id = paid_current_account_id())));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."mcp_server_definitions";
        CREATE POLICY "tenant_isolation" ON "public"."mcp_server_definitions" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (account_id = paid_current_account_id())))
          WITH CHECK ((paid_tenant_bypass() OR (account_id = paid_current_account_id())));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."model_selections";
        CREATE POLICY "tenant_isolation" ON "public"."model_selections" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM (agent_runs
             JOIN projects ON ((projects.id = agent_runs.project_id)))
          WHERE ((agent_runs.id = model_selections.agent_run_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM (agent_runs
             JOIN projects ON ((projects.id = agent_runs.project_id)))
          WHERE ((agent_runs.id = model_selections.agent_run_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."notification_rule_states";
        CREATE POLICY "tenant_isolation" ON "public"."notification_rule_states" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (account_id = paid_current_account_id())))
          WITH CHECK ((paid_tenant_bypass() OR (account_id = paid_current_account_id())));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."notifications";
        CREATE POLICY "tenant_isolation" ON "public"."notifications" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND ((user_id IS NULL) OR (EXISTS ( SELECT 1
           FROM users
          WHERE ((users.id = notifications.user_id) AND (users.account_id = paid_current_account_id()))))))))
          WITH CHECK ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND ((user_id IS NULL) OR (EXISTS ( SELECT 1
           FROM users
          WHERE ((users.id = notifications.user_id) AND (users.account_id = paid_current_account_id()))))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."onboarding_steps";
        CREATE POLICY "tenant_isolation" ON "public"."onboarding_steps" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (account_id = paid_current_account_id())))
          WITH CHECK ((paid_tenant_bypass() OR (account_id = paid_current_account_id())));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."orchestration_decisions";
        CREATE POLICY "tenant_isolation" ON "public"."orchestration_decisions" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = orchestration_decisions.project_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = orchestration_decisions.project_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."orchestration_strategies";
        CREATE POLICY "tenant_isolation" ON "public"."orchestration_strategies" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (account_id = paid_current_account_id())))
          WITH CHECK ((paid_tenant_bypass() OR (account_id = paid_current_account_id())));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."page_load_measurements";
        CREATE POLICY "tenant_isolation" ON "public"."page_load_measurements" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (account_id = paid_current_account_id())))
          WITH CHECK ((paid_tenant_bypass() OR (account_id = paid_current_account_id())));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."page_load_regression_findings";
        CREATE POLICY "tenant_isolation" ON "public"."page_load_regression_findings" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (account_id = paid_current_account_id())))
          WITH CHECK ((paid_tenant_bypass() OR (account_id = paid_current_account_id())));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."partial_closeout_projection_entries";
        CREATE POLICY "tenant_isolation" ON "public"."partial_closeout_projection_entries" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = partial_closeout_projection_entries.project_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = partial_closeout_projection_entries.project_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."partial_closeout_projections";
        CREATE POLICY "tenant_isolation" ON "public"."partial_closeout_projections" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = partial_closeout_projections.project_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = partial_closeout_projections.project_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."pending_install_claims";
        CREATE POLICY "tenant_isolation" ON "public"."pending_install_claims" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (account_id = paid_current_account_id())))
          WITH CHECK ((paid_tenant_bypass() OR (account_id = paid_current_account_id())));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."personal_access_tokens";
        CREATE POLICY "tenant_isolation" ON "public"."personal_access_tokens" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (account_id = paid_current_account_id())))
          WITH CHECK ((paid_tenant_bypass() OR (account_id = paid_current_account_id())));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."pr_templates";
        CREATE POLICY "tenant_isolation" ON "public"."pr_templates" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND ((project_id IS NULL) OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = pr_templates.project_id) AND (projects.account_id = paid_current_account_id()))))) AND ((user_id IS NULL) OR (EXISTS ( SELECT 1
           FROM users
          WHERE ((users.id = pr_templates.user_id) AND (users.account_id = paid_current_account_id()))))))))
          WITH CHECK ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND ((project_id IS NULL) OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = pr_templates.project_id) AND (projects.account_id = paid_current_account_id()))))) AND ((user_id IS NULL) OR (EXISTS ( SELECT 1
           FROM users
          WHERE ((users.id = pr_templates.user_id) AND (users.account_id = paid_current_account_id()))))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."pre_commit_requirements";
        CREATE POLICY "tenant_isolation" ON "public"."pre_commit_requirements" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND ((project_id IS NULL) OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = pre_commit_requirements.project_id) AND (projects.account_id = paid_current_account_id()))))) AND ((user_id IS NULL) OR (EXISTS ( SELECT 1
           FROM users
          WHERE ((users.id = pre_commit_requirements.user_id) AND (users.account_id = paid_current_account_id()))))))))
          WITH CHECK ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND ((project_id IS NULL) OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = pre_commit_requirements.project_id) AND (projects.account_id = paid_current_account_id()))))) AND ((user_id IS NULL) OR (EXISTS ( SELECT 1
           FROM users
          WHERE ((users.id = pre_commit_requirements.user_id) AND (users.account_id = paid_current_account_id()))))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."preview_sessions";
        CREATE POLICY "tenant_isolation" ON "public"."preview_sessions" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND ((project_id IS NULL) OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = preview_sessions.project_id) AND (projects.account_id = paid_current_account_id()))))))))
          WITH CHECK ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND ((project_id IS NULL) OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = preview_sessions.project_id) AND (projects.account_id = paid_current_account_id()))))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."project_baselines";
        CREATE POLICY "tenant_isolation" ON "public"."project_baselines" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = project_baselines.project_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = project_baselines.project_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."project_convention_detections";
        CREATE POLICY "tenant_isolation" ON "public"."project_convention_detections" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = project_convention_detections.project_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = project_convention_detections.project_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."project_convention_overrides";
        CREATE POLICY "tenant_isolation" ON "public"."project_convention_overrides" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = project_convention_overrides.project_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = project_convention_overrides.project_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."project_convention_recommendations";
        CREATE POLICY "tenant_isolation" ON "public"."project_convention_recommendations" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = project_convention_recommendations.project_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = project_convention_recommendations.project_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."project_delegation_postures";
        CREATE POLICY "tenant_isolation" ON "public"."project_delegation_postures" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = project_delegation_postures.project_id) AND (projects.account_id = paid_current_account_id())))) AND ((selected_by_id IS NULL) OR (EXISTS ( SELECT 1
           FROM users
          WHERE ((users.id = project_delegation_postures.selected_by_id) AND (users.account_id = paid_current_account_id()))))))))
          WITH CHECK ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = project_delegation_postures.project_id) AND (projects.account_id = paid_current_account_id())))) AND ((selected_by_id IS NULL) OR (EXISTS ( SELECT 1
           FROM users
          WHERE ((users.id = project_delegation_postures.selected_by_id) AND (users.account_id = paid_current_account_id()))))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."project_mcp_servers";
        CREATE POLICY "tenant_isolation" ON "public"."project_mcp_servers" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR ((EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = project_mcp_servers.project_id) AND (projects.account_id = paid_current_account_id())))) AND (EXISTS ( SELECT 1
           FROM mcp_server_definitions
          WHERE ((mcp_server_definitions.id = project_mcp_servers.mcp_server_definition_id) AND (mcp_server_definitions.account_id = paid_current_account_id())))))))
          WITH CHECK ((paid_tenant_bypass() OR ((EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = project_mcp_servers.project_id) AND (projects.account_id = paid_current_account_id())))) AND (EXISTS ( SELECT 1
           FROM mcp_server_definitions
          WHERE ((mcp_server_definitions.id = project_mcp_servers.mcp_server_definition_id) AND (mcp_server_definitions.account_id = paid_current_account_id())))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."project_memberships";
        CREATE POLICY "tenant_isolation" ON "public"."project_memberships" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR ((EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = project_memberships.project_id) AND (projects.account_id = paid_current_account_id())))) AND (EXISTS ( SELECT 1
           FROM users
          WHERE ((users.id = project_memberships.user_id) AND (users.account_id = paid_current_account_id())))))))
          WITH CHECK ((paid_tenant_bypass() OR ((EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = project_memberships.project_id) AND (projects.account_id = paid_current_account_id())))) AND (EXISTS ( SELECT 1
           FROM users
          WHERE ((users.id = project_memberships.user_id) AND (users.account_id = paid_current_account_id())))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."project_service_containers";
        CREATE POLICY "tenant_isolation" ON "public"."project_service_containers" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR ((EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = project_service_containers.project_id) AND (projects.account_id = paid_current_account_id())))) AND (EXISTS ( SELECT 1
           FROM service_containers
          WHERE ((service_containers.id = project_service_containers.service_container_id) AND (service_containers.account_id = paid_current_account_id())))))))
          WITH CHECK ((paid_tenant_bypass() OR ((EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = project_service_containers.project_id) AND (projects.account_id = paid_current_account_id())))) AND (EXISTS ( SELECT 1
           FROM service_containers
          WHERE ((service_containers.id = project_service_containers.service_container_id) AND (service_containers.account_id = paid_current_account_id())))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."project_versions";
        CREATE POLICY "tenant_isolation" ON "public"."project_versions" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = project_versions.project_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = project_versions.project_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."projects";
        CREATE POLICY "tenant_isolation" ON "public"."projects" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND ((EXISTS ( SELECT 1
           FROM github_tokens
          WHERE ((github_tokens.id = projects.github_token_id) AND (github_tokens.account_id = paid_current_account_id())))) OR (EXISTS ( SELECT 1
           FROM github_installations
          WHERE ((github_installations.id = projects.github_installation_id) AND (github_installations.account_id = paid_current_account_id()))))) AND ((created_by_id IS NULL) OR (EXISTS ( SELECT 1
           FROM users
          WHERE ((users.id = projects.created_by_id) AND (users.account_id = paid_current_account_id()))))))))
          WITH CHECK ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND ((EXISTS ( SELECT 1
           FROM github_tokens
          WHERE ((github_tokens.id = projects.github_token_id) AND (github_tokens.account_id = paid_current_account_id())))) OR (EXISTS ( SELECT 1
           FROM github_installations
          WHERE ((github_installations.id = projects.github_installation_id) AND (github_installations.account_id = paid_current_account_id()))))) AND ((created_by_id IS NULL) OR (EXISTS ( SELECT 1
           FROM users
          WHERE ((users.id = projects.created_by_id) AND (users.account_id = paid_current_account_id()))))))));
        DROP POLICY IF EXISTS "tenant_isolation_delete" ON "public"."prompt_versions";
        CREATE POLICY "tenant_isolation_delete" ON "public"."prompt_versions" AS PERMISSIVE FOR DELETE TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM prompts
          WHERE ((prompts.id = prompt_versions.prompt_id) AND (prompts.account_id = paid_current_account_id()) AND ((prompts.project_id IS NULL) OR (EXISTS ( SELECT 1
                   FROM projects
                  WHERE ((projects.id = prompts.project_id) AND (projects.account_id = paid_current_account_id()))))))))));
        DROP POLICY IF EXISTS "tenant_isolation_insert" ON "public"."prompt_versions";
        CREATE POLICY "tenant_isolation_insert" ON "public"."prompt_versions" AS PERMISSIVE FOR INSERT TO PUBLIC
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM prompts
          WHERE ((prompts.id = prompt_versions.prompt_id) AND (prompts.account_id = paid_current_account_id()) AND ((prompts.project_id IS NULL) OR (EXISTS ( SELECT 1
                   FROM projects
                  WHERE ((projects.id = prompts.project_id) AND (projects.account_id = paid_current_account_id()))))))))));
        DROP POLICY IF EXISTS "tenant_isolation_select" ON "public"."prompt_versions";
        CREATE POLICY "tenant_isolation_select" ON "public"."prompt_versions" AS PERMISSIVE FOR SELECT TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM prompts
          WHERE ((prompts.id = prompt_versions.prompt_id) AND ((prompts.account_id IS NULL) OR (prompts.account_id = paid_current_account_id())))))));
        DROP POLICY IF EXISTS "tenant_isolation_update" ON "public"."prompt_versions";
        CREATE POLICY "tenant_isolation_update" ON "public"."prompt_versions" AS PERMISSIVE FOR UPDATE TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM prompts
          WHERE ((prompts.id = prompt_versions.prompt_id) AND (prompts.account_id = paid_current_account_id()) AND ((prompts.project_id IS NULL) OR (EXISTS ( SELECT 1
                   FROM projects
                  WHERE ((projects.id = prompts.project_id) AND (projects.account_id = paid_current_account_id()))))))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM prompts
          WHERE ((prompts.id = prompt_versions.prompt_id) AND (prompts.account_id = paid_current_account_id()) AND ((prompts.project_id IS NULL) OR (EXISTS ( SELECT 1
                   FROM projects
                  WHERE ((projects.id = prompts.project_id) AND (projects.account_id = paid_current_account_id()))))))))));
        DROP POLICY IF EXISTS "tenant_isolation_delete" ON "public"."prompts";
        CREATE POLICY "tenant_isolation_delete" ON "public"."prompts" AS PERMISSIVE FOR DELETE TO PUBLIC
          USING ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND ((project_id IS NULL) OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = prompts.project_id) AND (projects.account_id = paid_current_account_id()))))))));
        DROP POLICY IF EXISTS "tenant_isolation_insert" ON "public"."prompts";
        CREATE POLICY "tenant_isolation_insert" ON "public"."prompts" AS PERMISSIVE FOR INSERT TO PUBLIC
          WITH CHECK ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND ((project_id IS NULL) OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = prompts.project_id) AND (projects.account_id = paid_current_account_id()))))))));
        DROP POLICY IF EXISTS "tenant_isolation_select" ON "public"."prompts";
        CREATE POLICY "tenant_isolation_select" ON "public"."prompts" AS PERMISSIVE FOR SELECT TO PUBLIC
          USING ((paid_tenant_bypass() OR ((account_id IS NULL) OR ((account_id = paid_current_account_id()) AND ((project_id IS NULL) OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = prompts.project_id) AND (projects.account_id = paid_current_account_id())))))))));
        DROP POLICY IF EXISTS "tenant_isolation_update" ON "public"."prompts";
        CREATE POLICY "tenant_isolation_update" ON "public"."prompts" AS PERMISSIVE FOR UPDATE TO PUBLIC
          USING ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND ((project_id IS NULL) OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = prompts.project_id) AND (projects.account_id = paid_current_account_id()))))))))
          WITH CHECK ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND ((project_id IS NULL) OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = prompts.project_id) AND (projects.account_id = paid_current_account_id()))))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."provider_api_keys";
        CREATE POLICY "tenant_isolation" ON "public"."provider_api_keys" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM users
          WHERE ((users.id = provider_api_keys.user_id) AND (users.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM users
          WHERE ((users.id = provider_api_keys.user_id) AND (users.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."provider_identity_mappings";
        CREATE POLICY "tenant_isolation" ON "public"."provider_identity_mappings" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (account_id = paid_current_account_id())))
          WITH CHECK ((paid_tenant_bypass() OR (account_id = paid_current_account_id())));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."provisioning_intents";
        CREATE POLICY "tenant_isolation" ON "public"."provisioning_intents" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND ((project_id IS NULL) OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = provisioning_intents.project_id) AND (projects.account_id = paid_current_account_id()))))) AND ((agent_run_id IS NULL) OR (EXISTS ( SELECT 1
           FROM (agent_runs
             JOIN projects ON ((projects.id = agent_runs.project_id)))
          WHERE ((agent_runs.id = provisioning_intents.agent_run_id) AND (projects.account_id = paid_current_account_id()))))))))
          WITH CHECK ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND ((project_id IS NULL) OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = provisioning_intents.project_id) AND (projects.account_id = paid_current_account_id()))))) AND ((agent_run_id IS NULL) OR (EXISTS ( SELECT 1
           FROM (agent_runs
             JOIN projects ON ((projects.id = agent_runs.project_id)))
          WHERE ((agent_runs.id = provisioning_intents.agent_run_id) AND (projects.account_id = paid_current_account_id()))))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."quality_gate_events";
        CREATE POLICY "tenant_isolation" ON "public"."quality_gate_events" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = quality_gate_events.project_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = quality_gate_events.project_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."quality_metrics";
        CREATE POLICY "tenant_isolation" ON "public"."quality_metrics" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM (agent_runs
             JOIN projects ON ((projects.id = agent_runs.project_id)))
          WHERE ((agent_runs.id = quality_metrics.agent_run_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM (agent_runs
             JOIN projects ON ((projects.id = agent_runs.project_id)))
          WHERE ((agent_runs.id = quality_metrics.agent_run_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."quality_pause_events";
        CREATE POLICY "tenant_isolation" ON "public"."quality_pause_events" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = quality_pause_events.project_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = quality_pause_events.project_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."quality_recovery_actions";
        CREATE POLICY "tenant_isolation" ON "public"."quality_recovery_actions" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = quality_recovery_actions.project_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = quality_recovery_actions.project_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."quality_thresholds";
        CREATE POLICY "tenant_isolation" ON "public"."quality_thresholds" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND ((project_id IS NULL) OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = quality_thresholds.project_id) AND (projects.account_id = paid_current_account_id()))))))))
          WITH CHECK ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND ((project_id IS NULL) OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = quality_thresholds.project_id) AND (projects.account_id = paid_current_account_id()))))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."remediation_decisions";
        CREATE POLICY "tenant_isolation" ON "public"."remediation_decisions" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (account_id = paid_current_account_id())))
          WITH CHECK ((paid_tenant_bypass() OR (account_id = paid_current_account_id())));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."roi_benchmarks";
        CREATE POLICY "tenant_isolation" ON "public"."roi_benchmarks" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = roi_benchmarks.project_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = roi_benchmarks.project_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."runner_auth_attempts";
        CREATE POLICY "tenant_isolation" ON "public"."runner_auth_attempts" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND ((project_id IS NULL) OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = runner_auth_attempts.project_id) AND (projects.account_id = paid_current_account_id()))))))))
          WITH CHECK ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND ((project_id IS NULL) OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = runner_auth_attempts.project_id) AND (projects.account_id = paid_current_account_id()))))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."runner_credentials";
        CREATE POLICY "tenant_isolation" ON "public"."runner_credentials" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (account_id = paid_current_account_id())))
          WITH CHECK ((paid_tenant_bypass() OR (account_id = paid_current_account_id())));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."runner_states";
        CREATE POLICY "tenant_isolation" ON "public"."runner_states" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM users
          WHERE ((users.id = runner_states.user_id) AND (users.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM users
          WHERE ((users.id = runner_states.user_id) AND (users.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."runners";
        CREATE POLICY "tenant_isolation" ON "public"."runners" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM users
          WHERE ((users.id = runners.user_id) AND (users.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM users
          WHERE ((users.id = runners.user_id) AND (users.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."scaling_experiment_assignments";
        CREATE POLICY "tenant_isolation" ON "public"."scaling_experiment_assignments" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = scaling_experiment_assignments.project_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = scaling_experiment_assignments.project_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."scaling_experiments";
        CREATE POLICY "tenant_isolation" ON "public"."scaling_experiments" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = scaling_experiments.project_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = scaling_experiments.project_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."scaling_observations";
        CREATE POLICY "tenant_isolation" ON "public"."scaling_observations" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = scaling_observations.project_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = scaling_observations.project_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."service_container_metrics";
        CREATE POLICY "tenant_isolation" ON "public"."service_container_metrics" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM service_containers
          WHERE ((service_containers.id = service_container_metrics.service_container_id) AND (service_containers.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM service_containers
          WHERE ((service_containers.id = service_container_metrics.service_container_id) AND (service_containers.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."service_containers";
        CREATE POLICY "tenant_isolation" ON "public"."service_containers" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (account_id = paid_current_account_id())))
          WITH CHECK ((paid_tenant_bypass() OR (account_id = paid_current_account_id())));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."staged_closeout_enrollments";
        CREATE POLICY "tenant_isolation" ON "public"."staged_closeout_enrollments" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = staged_closeout_enrollments.project_id) AND (projects.account_id = paid_current_account_id())))) AND ((reviewed_by_id IS NULL) OR (EXISTS ( SELECT 1
           FROM users
          WHERE ((users.id = staged_closeout_enrollments.reviewed_by_id) AND (users.account_id = paid_current_account_id()))))))))
          WITH CHECK ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = staged_closeout_enrollments.project_id) AND (projects.account_id = paid_current_account_id())))) AND ((reviewed_by_id IS NULL) OR (EXISTS ( SELECT 1
           FROM users
          WHERE ((users.id = staged_closeout_enrollments.reviewed_by_id) AND (users.account_id = paid_current_account_id()))))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."staged_closeout_mappings";
        CREATE POLICY "tenant_isolation" ON "public"."staged_closeout_mappings" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = staged_closeout_mappings.project_id) AND (projects.account_id = paid_current_account_id())))) AND (EXISTS ( SELECT 1
           FROM (issues
             JOIN projects ON ((projects.id = issues.project_id)))
          WHERE ((issues.id = staged_closeout_mappings.issue_id) AND (issues.project_id = staged_closeout_mappings.project_id) AND (projects.account_id = paid_current_account_id())))) AND (EXISTS ( SELECT 1
           FROM staged_closeout_enrollments
          WHERE ((staged_closeout_enrollments.id = staged_closeout_mappings.staged_closeout_enrollment_id) AND (staged_closeout_enrollments.project_id = staged_closeout_mappings.project_id) AND (staged_closeout_enrollments.account_id = paid_current_account_id())))) AND (EXISTS ( SELECT 1
           FROM users
          WHERE ((users.id = staged_closeout_mappings.reviewed_by_id) AND (users.account_id = paid_current_account_id())))) AND ((invalidated_by_id IS NULL) OR (EXISTS ( SELECT 1
           FROM users
          WHERE ((users.id = staged_closeout_mappings.invalidated_by_id) AND (users.account_id = paid_current_account_id()))))))))
          WITH CHECK ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = staged_closeout_mappings.project_id) AND (projects.account_id = paid_current_account_id())))) AND (EXISTS ( SELECT 1
           FROM (issues
             JOIN projects ON ((projects.id = issues.project_id)))
          WHERE ((issues.id = staged_closeout_mappings.issue_id) AND (issues.project_id = staged_closeout_mappings.project_id) AND (projects.account_id = paid_current_account_id())))) AND (EXISTS ( SELECT 1
           FROM staged_closeout_enrollments
          WHERE ((staged_closeout_enrollments.id = staged_closeout_mappings.staged_closeout_enrollment_id) AND (staged_closeout_enrollments.project_id = staged_closeout_mappings.project_id) AND (staged_closeout_enrollments.account_id = paid_current_account_id())))) AND (EXISTS ( SELECT 1
           FROM users
          WHERE ((users.id = staged_closeout_mappings.reviewed_by_id) AND (users.account_id = paid_current_account_id())))) AND ((invalidated_by_id IS NULL) OR (EXISTS ( SELECT 1
           FROM users
          WHERE ((users.id = staged_closeout_mappings.invalidated_by_id) AND (users.account_id = paid_current_account_id()))))))));
        DROP POLICY IF EXISTS "tenant_isolation_delete" ON "public"."strategies";
        CREATE POLICY "tenant_isolation_delete" ON "public"."strategies" AS PERMISSIVE FOR DELETE TO PUBLIC
          USING ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND ((project_id IS NULL) OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = strategies.project_id) AND (projects.account_id = paid_current_account_id()))))) AND ((current_version_id IS NULL) OR (EXISTS ( SELECT 1
           FROM strategy_versions
          WHERE ((strategy_versions.id = strategies.current_version_id) AND (strategy_versions.strategy_id = strategies.id))))))));
        DROP POLICY IF EXISTS "tenant_isolation_insert" ON "public"."strategies";
        CREATE POLICY "tenant_isolation_insert" ON "public"."strategies" AS PERMISSIVE FOR INSERT TO PUBLIC
          WITH CHECK ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND ((project_id IS NULL) OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = strategies.project_id) AND (projects.account_id = paid_current_account_id()))))) AND ((current_version_id IS NULL) OR (EXISTS ( SELECT 1
           FROM strategy_versions
          WHERE ((strategy_versions.id = strategies.current_version_id) AND (strategy_versions.strategy_id = strategies.id))))))));
        DROP POLICY IF EXISTS "tenant_isolation_select" ON "public"."strategies";
        CREATE POLICY "tenant_isolation_select" ON "public"."strategies" AS PERMISSIVE FOR SELECT TO PUBLIC
          USING ((paid_tenant_bypass() OR (((account_id IS NULL) OR ((account_id = paid_current_account_id()) AND ((project_id IS NULL) OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = strategies.project_id) AND (projects.account_id = paid_current_account_id()))))))) AND ((current_version_id IS NULL) OR (EXISTS ( SELECT 1
           FROM strategy_versions
          WHERE ((strategy_versions.id = strategies.current_version_id) AND (strategy_versions.strategy_id = strategies.id))))))));
        DROP POLICY IF EXISTS "tenant_isolation_update" ON "public"."strategies";
        CREATE POLICY "tenant_isolation_update" ON "public"."strategies" AS PERMISSIVE FOR UPDATE TO PUBLIC
          USING ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND ((project_id IS NULL) OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = strategies.project_id) AND (projects.account_id = paid_current_account_id()))))) AND ((current_version_id IS NULL) OR (EXISTS ( SELECT 1
           FROM strategy_versions
          WHERE ((strategy_versions.id = strategies.current_version_id) AND (strategy_versions.strategy_id = strategies.id))))))))
          WITH CHECK ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND ((project_id IS NULL) OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = strategies.project_id) AND (projects.account_id = paid_current_account_id()))))) AND ((current_version_id IS NULL) OR (EXISTS ( SELECT 1
           FROM strategy_versions
          WHERE ((strategy_versions.id = strategies.current_version_id) AND (strategy_versions.strategy_id = strategies.id))))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."strategy_experiment_assignments";
        CREATE POLICY "tenant_isolation" ON "public"."strategy_experiment_assignments" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM strategy_experiments
          WHERE ((strategy_experiments.id = strategy_experiment_assignments.strategy_experiment_id) AND (strategy_experiments.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM strategy_experiments
          WHERE ((strategy_experiments.id = strategy_experiment_assignments.strategy_experiment_id) AND (strategy_experiments.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."strategy_experiment_variants";
        CREATE POLICY "tenant_isolation" ON "public"."strategy_experiment_variants" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM strategy_experiments
          WHERE ((strategy_experiments.id = strategy_experiment_variants.strategy_experiment_id) AND (strategy_experiments.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM strategy_experiments
          WHERE ((strategy_experiments.id = strategy_experiment_variants.strategy_experiment_id) AND (strategy_experiments.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."strategy_experiments";
        CREATE POLICY "tenant_isolation" ON "public"."strategy_experiments" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (account_id = paid_current_account_id())))
          WITH CHECK ((paid_tenant_bypass() OR (account_id = paid_current_account_id())));
        DROP POLICY IF EXISTS "tenant_isolation_delete" ON "public"."strategy_versions";
        CREATE POLICY "tenant_isolation_delete" ON "public"."strategy_versions" AS PERMISSIVE FOR DELETE TO PUBLIC
          USING ((paid_tenant_bypass() OR ((EXISTS ( SELECT 1
           FROM strategies
          WHERE ((strategies.id = strategy_versions.strategy_id) AND ((strategies.account_id = paid_current_account_id()) AND ((strategies.project_id IS NULL) OR (EXISTS ( SELECT 1
                   FROM projects
                  WHERE ((projects.id = strategies.project_id) AND (projects.account_id = paid_current_account_id()))))))))) AND ((parent_version_id IS NULL) OR (EXISTS ( SELECT 1
           FROM strategy_versions parent_versions
          WHERE ((parent_versions.id = strategy_versions.parent_version_id) AND (parent_versions.strategy_id = strategy_versions.strategy_id))))) AND ((created_by_user_id IS NULL) OR (EXISTS ( SELECT 1
           FROM users
          WHERE ((users.id = strategy_versions.created_by_user_id) AND (users.account_id = paid_current_account_id()))))) AND ((promoted_by_user_id IS NULL) OR (EXISTS ( SELECT 1
           FROM users
          WHERE ((users.id = strategy_versions.promoted_by_user_id) AND (users.account_id = paid_current_account_id()))))))));
        DROP POLICY IF EXISTS "tenant_isolation_insert" ON "public"."strategy_versions";
        CREATE POLICY "tenant_isolation_insert" ON "public"."strategy_versions" AS PERMISSIVE FOR INSERT TO PUBLIC
          WITH CHECK ((paid_tenant_bypass() OR ((EXISTS ( SELECT 1
           FROM strategies
          WHERE ((strategies.id = strategy_versions.strategy_id) AND ((strategies.account_id = paid_current_account_id()) AND ((strategies.project_id IS NULL) OR (EXISTS ( SELECT 1
                   FROM projects
                  WHERE ((projects.id = strategies.project_id) AND (projects.account_id = paid_current_account_id()))))))))) AND ((parent_version_id IS NULL) OR (EXISTS ( SELECT 1
           FROM strategy_versions parent_versions
          WHERE ((parent_versions.id = strategy_versions.parent_version_id) AND (parent_versions.strategy_id = strategy_versions.strategy_id))))) AND ((created_by_user_id IS NULL) OR (EXISTS ( SELECT 1
           FROM users
          WHERE ((users.id = strategy_versions.created_by_user_id) AND (users.account_id = paid_current_account_id()))))) AND ((promoted_by_user_id IS NULL) OR (EXISTS ( SELECT 1
           FROM users
          WHERE ((users.id = strategy_versions.promoted_by_user_id) AND (users.account_id = paid_current_account_id()))))))));
        DROP POLICY IF EXISTS "tenant_isolation_select" ON "public"."strategy_versions";
        CREATE POLICY "tenant_isolation_select" ON "public"."strategy_versions" AS PERMISSIVE FOR SELECT TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM strategies
          WHERE ((strategies.id = strategy_versions.strategy_id) AND ((strategies.account_id IS NULL) OR ((strategies.account_id = paid_current_account_id()) AND ((strategies.project_id IS NULL) OR (EXISTS ( SELECT 1
                   FROM projects
                  WHERE ((projects.id = strategies.project_id) AND (projects.account_id = paid_current_account_id()))))))))))));
        DROP POLICY IF EXISTS "tenant_isolation_update" ON "public"."strategy_versions";
        CREATE POLICY "tenant_isolation_update" ON "public"."strategy_versions" AS PERMISSIVE FOR UPDATE TO PUBLIC
          USING ((paid_tenant_bypass() OR ((EXISTS ( SELECT 1
           FROM strategies
          WHERE ((strategies.id = strategy_versions.strategy_id) AND ((strategies.account_id = paid_current_account_id()) AND ((strategies.project_id IS NULL) OR (EXISTS ( SELECT 1
                   FROM projects
                  WHERE ((projects.id = strategies.project_id) AND (projects.account_id = paid_current_account_id()))))))))) AND ((parent_version_id IS NULL) OR (EXISTS ( SELECT 1
           FROM strategy_versions parent_versions
          WHERE ((parent_versions.id = strategy_versions.parent_version_id) AND (parent_versions.strategy_id = strategy_versions.strategy_id))))) AND ((created_by_user_id IS NULL) OR (EXISTS ( SELECT 1
           FROM users
          WHERE ((users.id = strategy_versions.created_by_user_id) AND (users.account_id = paid_current_account_id()))))) AND ((promoted_by_user_id IS NULL) OR (EXISTS ( SELECT 1
           FROM users
          WHERE ((users.id = strategy_versions.promoted_by_user_id) AND (users.account_id = paid_current_account_id()))))))))
          WITH CHECK ((paid_tenant_bypass() OR ((EXISTS ( SELECT 1
           FROM strategies
          WHERE ((strategies.id = strategy_versions.strategy_id) AND ((strategies.account_id = paid_current_account_id()) AND ((strategies.project_id IS NULL) OR (EXISTS ( SELECT 1
                   FROM projects
                  WHERE ((projects.id = strategies.project_id) AND (projects.account_id = paid_current_account_id()))))))))) AND ((parent_version_id IS NULL) OR (EXISTS ( SELECT 1
           FROM strategy_versions parent_versions
          WHERE ((parent_versions.id = strategy_versions.parent_version_id) AND (parent_versions.strategy_id = strategy_versions.strategy_id))))) AND ((created_by_user_id IS NULL) OR (EXISTS ( SELECT 1
           FROM users
          WHERE ((users.id = strategy_versions.created_by_user_id) AND (users.account_id = paid_current_account_id()))))) AND ((promoted_by_user_id IS NULL) OR (EXISTS ( SELECT 1
           FROM users
          WHERE ((users.id = strategy_versions.promoted_by_user_id) AND (users.account_id = paid_current_account_id()))))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."style_guide_ab_tests";
        CREATE POLICY "tenant_isolation" ON "public"."style_guide_ab_tests" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (account_id = paid_current_account_id())))
          WITH CHECK ((paid_tenant_bypass() OR (account_id = paid_current_account_id())));
        DROP POLICY IF EXISTS "tenant_isolation_delete" ON "public"."style_guides";
        CREATE POLICY "tenant_isolation_delete" ON "public"."style_guides" AS PERMISSIVE FOR DELETE TO PUBLIC
          USING ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND ((project_id IS NULL) OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = style_guides.project_id) AND (projects.account_id = paid_current_account_id()))))))));
        DROP POLICY IF EXISTS "tenant_isolation_insert" ON "public"."style_guides";
        CREATE POLICY "tenant_isolation_insert" ON "public"."style_guides" AS PERMISSIVE FOR INSERT TO PUBLIC
          WITH CHECK ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND ((project_id IS NULL) OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = style_guides.project_id) AND (projects.account_id = paid_current_account_id()))))))));
        DROP POLICY IF EXISTS "tenant_isolation_select" ON "public"."style_guides";
        CREATE POLICY "tenant_isolation_select" ON "public"."style_guides" AS PERMISSIVE FOR SELECT TO PUBLIC
          USING ((paid_tenant_bypass() OR ((account_id IS NULL) OR ((account_id = paid_current_account_id()) AND ((project_id IS NULL) OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = style_guides.project_id) AND (projects.account_id = paid_current_account_id())))))))));
        DROP POLICY IF EXISTS "tenant_isolation_update" ON "public"."style_guides";
        CREATE POLICY "tenant_isolation_update" ON "public"."style_guides" AS PERMISSIVE FOR UPDATE TO PUBLIC
          USING ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND ((project_id IS NULL) OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = style_guides.project_id) AND (projects.account_id = paid_current_account_id()))))))))
          WITH CHECK ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND ((project_id IS NULL) OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = style_guides.project_id) AND (projects.account_id = paid_current_account_id()))))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."supervisor_incident_audits";
        CREATE POLICY "tenant_isolation" ON "public"."supervisor_incident_audits" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (account_id = paid_current_account_id())))
          WITH CHECK ((paid_tenant_bypass() OR (account_id = paid_current_account_id())));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."supervisor_incidents";
        CREATE POLICY "tenant_isolation" ON "public"."supervisor_incidents" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (account_id = paid_current_account_id())))
          WITH CHECK ((paid_tenant_bypass() OR (account_id = paid_current_account_id())));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."supervisor_snapshots";
        CREATE POLICY "tenant_isolation" ON "public"."supervisor_snapshots" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (account_id = paid_current_account_id())))
          WITH CHECK ((paid_tenant_bypass() OR (account_id = paid_current_account_id())));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."tenant_settings";
        CREATE POLICY "tenant_isolation" ON "public"."tenant_settings" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (account_id = paid_current_account_id())))
          WITH CHECK ((paid_tenant_bypass() OR (account_id = paid_current_account_id())));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."token_usages";
        CREATE POLICY "tenant_isolation" ON "public"."token_usages" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (((agent_run_id IS NOT NULL) AND (EXISTS ( SELECT 1
           FROM (agent_runs
             JOIN projects ON ((projects.id = agent_runs.project_id)))
          WHERE ((agent_runs.id = token_usages.agent_run_id) AND (projects.account_id = paid_current_account_id()))))) OR ((knowledge_run_id IS NOT NULL) AND (EXISTS ( SELECT 1
           FROM (knowledge_runs
             JOIN projects ON ((projects.id = knowledge_runs.project_id)))
          WHERE ((knowledge_runs.id = token_usages.knowledge_run_id) AND (projects.account_id = paid_current_account_id()))))) OR ((chat_session_id IS NOT NULL) AND (EXISTS ( SELECT 1
           FROM chat_sessions
          WHERE ((chat_sessions.id = token_usages.chat_session_id) AND (chat_sessions.account_id = paid_current_account_id()))))))))
          WITH CHECK ((paid_tenant_bypass() OR (((agent_run_id IS NOT NULL) AND (EXISTS ( SELECT 1
           FROM (agent_runs
             JOIN projects ON ((projects.id = agent_runs.project_id)))
          WHERE ((agent_runs.id = token_usages.agent_run_id) AND (projects.account_id = paid_current_account_id()))))) OR ((knowledge_run_id IS NOT NULL) AND (EXISTS ( SELECT 1
           FROM (knowledge_runs
             JOIN projects ON ((projects.id = knowledge_runs.project_id)))
          WHERE ((knowledge_runs.id = token_usages.knowledge_run_id) AND (projects.account_id = paid_current_account_id()))))) OR ((chat_session_id IS NOT NULL) AND (EXISTS ( SELECT 1
           FROM chat_sessions
          WHERE ((chat_sessions.id = token_usages.chat_session_id) AND (chat_sessions.account_id = paid_current_account_id()))))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."tracker_configurations";
        CREATE POLICY "tenant_isolation" ON "public"."tracker_configurations" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR ((((configurable_type)::text = 'Account'::text) AND (configurable_id = paid_current_account_id())) OR (((configurable_type)::text = 'Project'::text) AND (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = tracker_configurations.configurable_id) AND (projects.account_id = paid_current_account_id()))))))))
          WITH CHECK ((paid_tenant_bypass() OR ((((configurable_type)::text = 'Account'::text) AND (configurable_id = paid_current_account_id())) OR (((configurable_type)::text = 'Project'::text) AND (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = tracker_configurations.configurable_id) AND (projects.account_id = paid_current_account_id()))))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."trusted_measurement_attempts";
        CREATE POLICY "tenant_isolation" ON "public"."trusted_measurement_attempts" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = trusted_measurement_attempts.project_id) AND (projects.account_id = paid_current_account_id())))) AND ((issue_id IS NULL) OR (EXISTS ( SELECT 1
           FROM issues
          WHERE ((issues.id = trusted_measurement_attempts.issue_id) AND (issues.project_id = trusted_measurement_attempts.project_id))))))))
          WITH CHECK ((paid_tenant_bypass() OR ((account_id = paid_current_account_id()) AND (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = trusted_measurement_attempts.project_id) AND (projects.account_id = paid_current_account_id())))) AND ((issue_id IS NULL) OR (EXISTS ( SELECT 1
           FROM issues
          WHERE ((issues.id = trusted_measurement_attempts.issue_id) AND (issues.project_id = trusted_measurement_attempts.project_id))))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."trusted_provider_identities";
        CREATE POLICY "tenant_isolation" ON "public"."trusted_provider_identities" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (account_id = paid_current_account_id())))
          WITH CHECK ((paid_tenant_bypass() OR (account_id = paid_current_account_id())));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."user_settings";
        CREATE POLICY "tenant_isolation" ON "public"."user_settings" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM users
          WHERE ((users.id = user_settings.user_id) AND (users.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM users
          WHERE ((users.id = user_settings.user_id) AND (users.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."users";
        CREATE POLICY "tenant_isolation" ON "public"."users" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (account_id = paid_current_account_id())))
          WITH CHECK ((paid_tenant_bypass() OR (account_id = paid_current_account_id())));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."work_item_assignment_overrides";
        CREATE POLICY "tenant_isolation" ON "public"."work_item_assignment_overrides" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (account_id = paid_current_account_id())))
          WITH CHECK ((paid_tenant_bypass() OR (account_id = paid_current_account_id())));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."work_item_assignments";
        CREATE POLICY "tenant_isolation" ON "public"."work_item_assignments" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (account_id = paid_current_account_id())))
          WITH CHECK ((paid_tenant_bypass() OR (account_id = paid_current_account_id())));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."work_item_lifecycle_conflicts";
        CREATE POLICY "tenant_isolation" ON "public"."work_item_lifecycle_conflicts" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (account_id = paid_current_account_id())))
          WITH CHECK ((paid_tenant_bypass() OR (account_id = paid_current_account_id())));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."work_item_lifecycle_mappings";
        CREATE POLICY "tenant_isolation" ON "public"."work_item_lifecycle_mappings" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (account_id = paid_current_account_id())))
          WITH CHECK ((paid_tenant_bypass() OR (account_id = paid_current_account_id())));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."work_item_project_mapping_targets";
        CREATE POLICY "tenant_isolation" ON "public"."work_item_project_mapping_targets" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM work_item_project_mappings
          WHERE ((work_item_project_mappings.id = work_item_project_mapping_targets.work_item_project_mapping_id) AND (work_item_project_mappings.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM work_item_project_mappings
          WHERE ((work_item_project_mappings.id = work_item_project_mapping_targets.work_item_project_mapping_id) AND (work_item_project_mappings.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."work_item_project_mappings";
        CREATE POLICY "tenant_isolation" ON "public"."work_item_project_mappings" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (account_id = paid_current_account_id())))
          WITH CHECK ((paid_tenant_bypass() OR (account_id = paid_current_account_id())));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."work_items";
        CREATE POLICY "tenant_isolation" ON "public"."work_items" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (account_id = paid_current_account_id())))
          WITH CHECK ((paid_tenant_bypass() OR (account_id = paid_current_account_id())));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."workflow_states";
        CREATE POLICY "tenant_isolation" ON "public"."workflow_states" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = workflow_states.project_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = workflow_states.project_id) AND (projects.account_id = paid_current_account_id()))))));
        DROP POLICY IF EXISTS "tenant_isolation" ON "public"."worktrees";
        CREATE POLICY "tenant_isolation" ON "public"."worktrees" AS PERMISSIVE FOR ALL TO PUBLIC
          USING ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = worktrees.project_id) AND (projects.account_id = paid_current_account_id()))))))
          WITH CHECK ((paid_tenant_bypass() OR (EXISTS ( SELECT 1
           FROM projects
          WHERE ((projects.id = worktrees.project_id) AND (projects.account_id = paid_current_account_id()))))));
        ALTER TABLE "public"."ab_test_assignments" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."ab_test_assignments" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."ab_test_variants" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."ab_test_variants" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."ab_tests" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."ab_tests" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."account_activity_events" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."account_activity_events" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."account_memberships" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."account_memberships" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."accounts" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."accounts" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."agent_coordination_signals" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."agent_coordination_signals" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."agent_images" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."agent_images" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."agent_run_anomalies" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."agent_run_anomalies" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."agent_run_logs" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."agent_run_logs" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."agent_run_phases" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."agent_run_phases" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."agent_run_resource_profiles" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."agent_run_resource_profiles" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."agent_run_session_summaries" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."agent_run_session_summaries" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."agent_runs" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."agent_runs" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."api_usage_attempts" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."api_usage_attempts" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."apple_verification_artifacts" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."apple_verification_artifacts" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."apple_verification_attempts" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."apple_verification_attempts" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."apple_verification_images" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."apple_verification_images" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."apple_verification_waivers" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."apple_verification_waivers" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."apple_verification_worker_healths" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."apple_verification_worker_healths" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."apple_verification_workflow_revisions" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."apple_verification_workflow_revisions" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."apple_worker_profiles" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."apple_worker_profiles" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."auto_merge_attempts" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."auto_merge_attempts" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."billing_invoices" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."billing_invoices" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."billing_line_items" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."billing_line_items" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."billing_periods" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."billing_periods" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."billing_plans" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."billing_plans" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."bounded_delegated_actions" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."bounded_delegated_actions" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."bundle_outcomes" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."bundle_outcomes" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."change_intents" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."change_intents" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."chat_diagram_comments" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."chat_diagram_comments" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."chat_diagrams" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."chat_diagrams" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."chat_investigations" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."chat_investigations" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."chat_messages" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."chat_messages" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."chat_session_projects" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."chat_session_projects" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."chat_sessions" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."chat_sessions" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."chat_turn_lifecycle_events" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."chat_turn_lifecycle_events" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."chat_turns" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."chat_turns" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."clarifying_question_progresses" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."clarifying_question_progresses" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."collector_runs" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."collector_runs" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."configuration_bundles" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."configuration_bundles" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."configuration_experiments" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."configuration_experiments" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."container_metrics" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."container_metrics" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."container_pool_entries" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."container_pool_entries" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."context_intake_questions" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."context_intake_questions" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."context_intake_responses" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."context_intake_responses" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."context_intake_sessions" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."context_intake_sessions" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."coordination_experiment_assignments" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."coordination_experiment_assignments" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."coordination_experiments" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."coordination_experiments" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."coordination_policies" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."coordination_policies" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."coordination_policy_versions" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."coordination_policy_versions" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."cost_budgets" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."cost_budgets" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."decision_record_links" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."decision_record_links" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."decision_records" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."decision_records" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."decomposition_decisions" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."decomposition_decisions" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."dependabot_alert_coverages" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."dependabot_alert_coverages" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."design_amendment_follow_ups" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."design_amendment_follow_ups" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."design_amendment_pauses" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."design_amendment_pauses" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."design_amendments" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."design_amendments" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."design_artifact_associations" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."design_artifact_associations" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."design_artifact_findings" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."design_artifact_findings" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."dispatch_circuit_breakers" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."dispatch_circuit_breakers" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."docker_hosts" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."docker_hosts" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."egress_allowlist_entries" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."egress_allowlist_entries" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."egress_security_events" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."egress_security_events" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."exception_incidents" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."exception_incidents" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."execution_audit_events" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."execution_audit_events" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."execution_controls" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."execution_controls" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."execution_resource_ledger_entries" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."execution_resource_ledger_entries" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."execution_resources" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."execution_resources" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."execution_usages" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."execution_usages" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."explicit_preferences" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."explicit_preferences" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."external_connector_events" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."external_connector_events" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."facet_confidence_evaluation_label_revisions" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."facet_confidence_evaluation_label_revisions" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."facet_confidence_evaluation_labels" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."facet_confidence_evaluation_labels" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."facet_confidence_evaluations" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."facet_confidence_evaluations" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."failure_classifications" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."failure_classifications" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."feature_intent_approval_revisions" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."feature_intent_approval_revisions" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."feature_intent_completions" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."feature_intent_completions" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."feature_intent_decisions" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."feature_intent_decisions" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."feature_intent_design_prs" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."feature_intent_design_prs" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."feature_intent_facet_assessments" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."feature_intent_facet_assessments" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."feature_intent_facet_directions" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."feature_intent_facet_directions" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."feature_intent_facet_evidence" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."feature_intent_facet_evidence" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."feature_intent_facets" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."feature_intent_facets" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."feature_intent_forward_work_items" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."feature_intent_forward_work_items" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."feature_intent_issue_dependencies" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."feature_intent_issue_dependencies" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."feature_intent_issue_prerequisite_mappings" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."feature_intent_issue_prerequisite_mappings" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."feature_intent_issue_prerequisites" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."feature_intent_issue_prerequisites" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."feature_intent_issues" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."feature_intent_issues" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."feature_intents" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."feature_intents" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."github_installations" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."github_installations" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."github_tokens" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."github_tokens" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."inbox_history_events" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."inbox_history_events" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."integration_credentials" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."integration_credentials" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."intent_conformance_decisions" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."intent_conformance_decisions" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."intent_conformance_resolutions" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."intent_conformance_resolutions" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."intent_conformance_review_schedules" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."intent_conformance_review_schedules" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."intent_conformance_shadow_evaluation_labels" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."intent_conformance_shadow_evaluation_labels" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."intent_conformance_shadow_evaluation_runs" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."intent_conformance_shadow_evaluation_runs" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."intent_conformance_shadow_evaluations" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."intent_conformance_shadow_evaluations" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."intent_conformance_verdicts" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."intent_conformance_verdicts" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."issue_continuation_requests" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."issue_continuation_requests" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."issue_dependencies" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."issue_dependencies" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."issue_merge_subscriptions" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."issue_merge_subscriptions" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."issues" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."issues" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."knowledge_artifacts" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."knowledge_artifacts" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."knowledge_audit_events" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."knowledge_audit_events" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."knowledge_chunks" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."knowledge_chunks" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."knowledge_links" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."knowledge_links" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."knowledge_recommendations" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."knowledge_recommendations" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."knowledge_runs" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."knowledge_runs" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."knowledge_usage_stats" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."knowledge_usage_stats" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."layered_verification_check_results" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."layered_verification_check_results" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."layered_verification_correspondence_claims" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."layered_verification_correspondence_claims" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."layered_verification_findings" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."layered_verification_findings" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."layered_verification_obligations" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."layered_verification_obligations" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."layered_verification_review_approvals" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."layered_verification_review_approvals" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."layered_verification_review_packages" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."layered_verification_review_packages" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."linear_tokens" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."linear_tokens" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."llm_output_metrics" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."llm_output_metrics" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."maintenance_finding_occurrences" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."maintenance_finding_occurrences" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."maintenance_findings" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."maintenance_findings" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."maintenance_reports" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."maintenance_reports" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."marketplace_entries" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."marketplace_entries" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."mcp_server_definitions" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."mcp_server_definitions" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."model_selections" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."model_selections" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."notification_rule_states" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."notification_rule_states" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."notifications" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."notifications" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."onboarding_steps" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."onboarding_steps" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."orchestration_decisions" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."orchestration_decisions" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."orchestration_strategies" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."orchestration_strategies" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."page_load_measurements" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."page_load_measurements" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."page_load_regression_findings" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."page_load_regression_findings" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."partial_closeout_projection_entries" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."partial_closeout_projection_entries" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."partial_closeout_projections" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."partial_closeout_projections" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."pending_install_claims" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."pending_install_claims" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."personal_access_tokens" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."personal_access_tokens" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."pr_templates" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."pr_templates" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."pre_commit_requirements" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."pre_commit_requirements" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."preview_sessions" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."preview_sessions" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."project_baselines" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."project_baselines" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."project_convention_detections" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."project_convention_detections" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."project_convention_overrides" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."project_convention_overrides" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."project_convention_recommendations" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."project_convention_recommendations" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."project_delegation_postures" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."project_delegation_postures" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."project_mcp_servers" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."project_mcp_servers" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."project_memberships" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."project_memberships" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."project_service_containers" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."project_service_containers" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."project_versions" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."project_versions" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."projects" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."projects" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."prompt_versions" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."prompt_versions" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."prompts" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."prompts" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."provider_api_keys" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."provider_api_keys" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."provider_identity_mappings" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."provider_identity_mappings" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."provisioning_intents" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."provisioning_intents" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."quality_gate_events" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."quality_gate_events" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."quality_metrics" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."quality_metrics" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."quality_pause_events" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."quality_pause_events" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."quality_recovery_actions" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."quality_recovery_actions" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."quality_thresholds" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."quality_thresholds" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."remediation_decisions" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."remediation_decisions" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."roi_benchmarks" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."roi_benchmarks" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."runner_auth_attempts" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."runner_auth_attempts" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."runner_credentials" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."runner_credentials" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."runner_states" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."runner_states" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."runners" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."runners" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."scaling_experiment_assignments" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."scaling_experiment_assignments" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."scaling_experiments" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."scaling_experiments" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."scaling_observations" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."scaling_observations" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."service_container_metrics" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."service_container_metrics" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."service_containers" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."service_containers" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."staged_closeout_enrollments" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."staged_closeout_enrollments" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."staged_closeout_mappings" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."staged_closeout_mappings" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."strategies" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."strategies" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."strategy_experiment_assignments" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."strategy_experiment_assignments" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."strategy_experiment_variants" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."strategy_experiment_variants" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."strategy_experiments" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."strategy_experiments" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."strategy_versions" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."strategy_versions" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."style_guide_ab_tests" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."style_guide_ab_tests" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."style_guides" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."style_guides" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."supervisor_incident_audits" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."supervisor_incident_audits" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."supervisor_incidents" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."supervisor_incidents" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."supervisor_snapshots" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."supervisor_snapshots" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."tenant_settings" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."tenant_settings" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."token_usages" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."token_usages" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."tracker_configurations" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."tracker_configurations" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."trusted_measurement_attempts" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."trusted_measurement_attempts" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."trusted_provider_identities" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."trusted_provider_identities" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."user_settings" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."user_settings" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."users" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."users" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."work_item_assignment_overrides" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."work_item_assignment_overrides" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."work_item_assignments" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."work_item_assignments" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."work_item_lifecycle_conflicts" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."work_item_lifecycle_conflicts" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."work_item_lifecycle_mappings" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."work_item_lifecycle_mappings" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."work_item_project_mapping_targets" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."work_item_project_mapping_targets" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."work_item_project_mappings" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."work_item_project_mappings" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."work_items" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."work_items" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."workflow_states" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."workflow_states" FORCE ROW LEVEL SECURITY;
        ALTER TABLE "public"."worktrees" ENABLE ROW LEVEL SECURITY;
        ALTER TABLE "public"."worktrees" FORCE ROW LEVEL SECURITY;
        SQL
      end
    end
  end

  def down
    # A corrective rollback must not restore missing or weaker boundaries.
  end
end
