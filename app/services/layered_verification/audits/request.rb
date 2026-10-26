# frozen_string_literal: true

module LayeredVerification
  module Audits
    # Records an audit request: it resolves the bounded scope, builds the
    # verification plan, and stores the request with its provenance so the
    # resolved scope, sources, target revision, and budget can be shown
    # before the run is dispatched.
    #
    # @spec LAYERED-VERIFY-010 @spec LAYERED-VERIFY-013 @spec LAYERED-VERIFY-020
    class Request
      Result = Data.define(:audit, :scope, :plan)

      def self.call(...)
        new(...).call
      end

      def initialize(project:, user:, scope_description:, sources:, target_revision: nil, budget: {},
        trigger_type: "manual_ui", scope_resolver: nil, plan_builder: nil, artifacts: nil)
        @project = project
        @user = user
        @scope_description = scope_description
        @sources = sources
        @target_revision = target_revision
        @budget = budget
        @trigger_type = trigger_type
        @scope_resolver = scope_resolver
        @plan_builder = plan_builder
        @artifacts = artifacts
      end

      def call
        AuditAccess.authorize!(user:, project:)

        scope = resolve_scope
        plan = build_plan(scope)

        Result.new(audit: record(scope, plan), scope:, plan:)
      end

      private

      attr_reader :artifacts, :budget, :plan_builder, :project, :scope_description, :scope_resolver, :sources,
        :target_revision, :trigger_type, :user

      def resolve_scope
        resolver = scope_resolver || ResolveScope
        resolver.call(
          project: project,
          scope_description: scope_description,
          sources: sources,
          target_revision: target_revision,
          budget: budget
        )
      end

      def build_plan(scope)
        builder = plan_builder || BuildPlan
        builder.call(
          project: project,
          obligations: scope.obligations,
          scope: scope,
          artifacts: resolved_artifacts(scope)
        )
      end

      def resolved_artifacts(scope)
        return artifacts if artifacts

        Projects::Artifacts.call(project: project, revision: scope.target_revision)
      end

      def record(scope, plan)
        LayeredVerificationAudit.create!(
          project: project,
          initiating_user: user,
          trigger_type: trigger_type,
          status: "planned",
          scope_description: scope.scope_description,
          sources: scope.sources,
          target_revision: scope.target_revision,
          budget: scope.budget,
          plan: plan.document.merge("artifacts" => resolved_artifacts(scope)),
          plan_revision: plan.document["revision"]
        )
      end
    end
  end
end
