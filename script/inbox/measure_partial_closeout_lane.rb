# frozen_string_literal: true

# Measures the Inbox `partial_closeout` lane's admission cost on the request
# path (#4558). The lane evaluates live auto-pick admission
# (`DefaultCandidateSource.eligible_scope`) for every project that has
# closeout candidates, so this script reports, per scenario:
#
# * how many SQL statements each consumer issues, and how long they take,
# * how many `eligible_scope` evaluations each consumer triggers,
# * the Postgres planning and execution time of the eligibility SQL itself.
#
# Run it against a database whose schema is loaded and whose tenant
# row-level-security policies are enabled (the shape of a migrated
# development database), using a role that does not bypass RLS:
#
#     RAILS_ENV=test \
#       PRIMARY_DATABASE_URL=postgres://user:pass@host:5432/paid_measure \
#       bin/rails runner script/inbox/measure_partial_closeout_lane.rb
#
# Each scenario owns a separate operator, so the operator sees exactly the
# seeded projects. Everything is seeded inside a transaction that is rolled
# back afterwards, so the measured database is left unchanged.

ENV["RAILS_ENV"] ||= "test"
ENV["PAID_SKIP_DATABASE_RUNTIME_ROLE_GUARD"] = "true"

require_relative "../../config/environment"
require "factory_bot_rails"

Rails.application.eager_load!
FactoryBot.reload

module Script
  module InboxMeasurement
    # Counts `eligible_scope` evaluations without changing its behavior.
    module EligibleScopeProbe
      class << self
        attr_accessor :calls
      end

      def eligible_scope(...)
        EligibleScopeProbe.calls += 1
        super
      end
    end

    # Measures the request-path cost of the partial-closeout Inbox lane.
    class MeasurePartialCloseoutLane
      include FactoryBot::Syntax::Methods

      PROJECT_COUNTS = [ 1, 5, 10, 20 ].freeze
      IGNORED_QUERY_NAMES = %w[SCHEMA TRANSACTION CACHE].freeze
      EXPLAIN_PREFIX = "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) ".freeze

      def self.call(...)
        new(...).call
      end

      def initialize(output: $stdout)
        @output = output
      end

      def call
        measured = scenarios
        report = {
          "environment" => environment,
          "scenarios" => measured,
          "eligibility_sql" => @eligibility_report
        }
        output.puts JSON.pretty_generate(report)
        report
      end

      private

      attr_reader :output

      def environment
        connection = ActiveRecord::Base.connection
        {
          "database" => connection.current_database,
          "adapter" => connection.adapter_name,
          "server_version" => connection.select_value("SHOW server_version"),
          "runtime_role" => connection.select_value("SELECT current_user"),
          "cache_store" => Rails.cache.class.name,
          "row_level_security_policies" => connection.select_value("SELECT count(*) FROM pg_policies").to_i,
          "seeded_projects" => @seeded_projects,
          "seeded_stalled_issues" => @seeded_stalled_issues
        }
      end

      def scenarios
        @seeded_projects = 0
        @seeded_stalled_issues = 0
        TenantContext.with_system_access { @account = create(:account) }

        TenantContext.with(@account) do
          ActiveRecord::Base.transaction do
            measured = PROJECT_COUNTS.map { |count| measure(count) }
            @eligibility_report = eligibility_sql_report
            measured
          end
        end
      end

      # One operator who owns exactly `count` projects, each holding a
      # stalled partial closeout plus an ordinary open issue.
      def measure(count)
        user = create(:user, account: @account)
        projects = seed_projects(count, user)

        {
          "projects" => count,
          "stalled_closeouts" => measure_call { Issues::StalledCloseouts.call(projects) },
          "inbox_queue" => measure_call { Inbox::Queue.call(user: user) },
          "inbox_queue_partial_closeout_only" => measure_call do
            Inbox::Queue.call(user: user, kind: Inbox::Queue::PARTIAL_CLOSEOUT_KIND)
          end,
          "inbox_count" => measure_call { Inbox::Count.call(user: user) },
          "inbox_availability" => measure_call { Inbox::Availability.new(user: user).kind_counts }
        }
      end

      def seed_projects(count, user)
        count.times.map do |index|
          project = create(:project, account: @account, created_by: user, owner: "acme", repo: "repo-#{index}")
          create(:issue, project: project, paid_state: "in_progress")
          @seeded_stalled_issues += 1 if create_stall(project)
          @seeded_projects += 1
          project
        end
      end

      # A merged partial PR linked to its source issue is the terminal
      # closeout evidence that puts an issue in the lane.
      def create_stall(project)
        issue = create(:issue, project: project, paid_state: "in_progress")
        create(
          :issue,
          :pull_request,
          project: project,
          github_number: issue.github_number + 1_000,
          github_state: "closed",
          pr_review_phase: "merged",
          parent_issue_id: issue.id
        )
        issue
      end

      # Runs the block with SQL and `eligible_scope` instrumentation and
      # reports what it cost.
      def measure_call
        statements = []
        subscriber = lambda do |_name, started, finished, _id, payload|
          next if IGNORED_QUERY_NAMES.include?(payload[:name]) || payload[:cached]

          statements << { name: payload[:name], duration_ms: (finished - started) * 1_000, sql: payload[:sql] }
        end
        EligibleScopeProbe.calls = 0
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { yield }
        wall_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000

        {
          "queries" => statements.size,
          "sql_ms" => statements.sum { |statement| statement[:duration_ms] }.round(2),
          "wall_ms" => wall_ms.round(2),
          "eligible_scope_evaluations" => EligibleScopeProbe.calls,
          "statements_by_name" => statements.group_by { |statement| statement[:name] }.transform_values(&:size),
          "slowest_statements" => statements.sort_by { |statement| -statement[:duration_ms] }.first(3).map { |statement|
            { "name" => statement[:name], "ms" => statement[:duration_ms].round(2), "sql" => statement[:sql].to_s.squish[0, 300] }
          }
        }
      end

      # Planning and execution cost of the eligibility SQL itself, with and
      # without the tenant policies applied to the plan.
      def eligibility_sql_report
        project = Project.order(:id).last
        scope = Automation::Strategies::AutoPick::DefaultCandidateSource.eligible_scope(project)
        sql = scope.to_sql
        simple_scope = Issue.where(project_id: project.id)

        {
          "sql_bytes" => sql.bytesize,
          "exists_clauses" => sql.scan("EXISTS").size,
          "tenant_policies_applied" => plan_report(scope),
          "tenant_policies_bypassed" => with_tenant_bypass { plan_report(scope) },
          "simple_statement_with_policies" => plan_report(simple_scope),
          "simple_statement_with_policies_bypassed" => with_tenant_bypass { plan_report(simple_scope) }
        }
      end

      def plan_report(scope)
        plan = ActiveRecord::Base.connection.raw_connection.exec(EXPLAIN_PREFIX + scope.to_sql).first.fetch("QUERY PLAN")
        parsed = JSON.parse(plan).first
        {
          "planning_ms" => parsed["Planning Time"],
          "execution_ms" => parsed["Execution Time"]
        }
      end

      def with_tenant_bypass
        ActiveRecord::Base.connection.execute("SELECT set_config('paid.bypass_tenant_rls', 'true', false)")
        yield
      ensure
        ActiveRecord::Base.connection.execute("SELECT set_config('paid.bypass_tenant_rls', 'false', false)")
      end
    end
  end
end

Automation::Strategies::AutoPick::DefaultCandidateSource.singleton_class.prepend(Script::InboxMeasurement::EligibleScopeProbe)
Script::InboxMeasurement::MeasurePartialCloseoutLane.call
