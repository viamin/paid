# frozen_string_literal: true

module Accounts
  module Adoption
    class Dashboard
      WINDOW_DAYS = 30
      FEATURE_SIGNALS = [
        {
          label: "Auto-pick rollout",
          key: :auto_pick_rollout
        },
        {
          label: "Automated review",
          key: :automated_review
        },
        {
          label: "Pre-commit guardrails",
          key: :pre_commit_guardrails
        },
        {
          label: "PR templates",
          key: :pr_templates
        },
        {
          label: "Quality gates",
          key: :quality_gates
        },
        {
          label: "Knowledge evolution",
          key: :knowledge_evolution
        },
        {
          label: "Marketplace auto-attach",
          key: :marketplace_auto_attach
        }
      ].freeze

      PLAYBOOKS = [
        {
          title: "Pilot rollout",
          audience: "Platform owner + pilot engineering manager",
          summary: "Start with one representative team, one reviewer path, and explicit success criteria before expanding.",
          steps: [
            "Pick 1-2 repositories with stable maintainers and recurring backlog.",
            "Enable automation-on-label first, then promote to auto-pick after two clean review cycles.",
            "Review run outcomes, reviewer feedback, and exception handling every week."
          ]
        },
        {
          title: "Guardrail tuning",
          audience: "Platform admin + security reviewer",
          summary: "Tighten automation defaults based on observed failure modes instead of one-off anecdotes.",
          steps: [
            "Baseline max concurrent runs, token ceilings, and monthly budget alerts before broader rollout.",
            "Use pre-commit requirements and PR templates to standardize what every automated change must satisfy.",
            "Escalate quality gates only after teams can explain why recent runs passed or paused."
          ]
        },
        {
          title: "Operating-model design",
          audience: "Platform lead + engineering leadership",
          summary: "Clarify who owns policy, who tunes projects, and who approves production expansion.",
          steps: [
            "Separate tenant-wide defaults from project-level autonomy up front.",
            "Define a weekly review owner for adoption analytics, blockers, and override trends.",
            "Document when teams can self-serve versus when platform review is required."
          ]
        }
      ].freeze

      OPERATING_MODELS = [
        {
          title: "Centralized platform ownership",
          best_for: "Regulated environments, shared platform teams, and tightly controlled policy changes.",
          strengths: [
            "Consistent guardrails, templates, and review policy across repositories.",
            "Faster security sign-off because control ownership is explicit.",
            "Simpler pilot expansion when engineering teams need hands-on support."
          ]
        },
        {
          title: "Team-owned deployments",
          best_for: "Product orgs with strong local ownership and teams that already manage repo automation.",
          strengths: [
            "Faster experimentation in project settings and review methods.",
            "Lower central bottleneck once the rollout pattern is understood.",
            "Teams can tailor prompts, templates, and guardrails to repo-specific workflows."
          ]
        }
      ].freeze

      TRACKS = [
        {
          key: :developers,
          title: "Developers",
          duration: "30 minutes",
          outcome: "Know how to trigger Paid safely, shape issues for success, and interpret run output.",
          modules: [
            "When to use manual runs vs automation labels",
            "How to write issues that avoid clarification loops",
            "How to respond when Paid pauses or requests more context"
          ]
        },
        {
          key: :reviewers,
          title: "Reviewers",
          duration: "30 minutes",
          outcome: "Review Paid PRs consistently and distinguish policy issues from model issues.",
          modules: [
            "Review expectations for Paid-generated PRs",
            "Using PR templates and pre-commit evidence during review",
            "Escalation path when automation should be paused or retried"
          ]
        },
        {
          key: :managers,
          title: "Managers",
          duration: "20 minutes",
          outcome: "Track adoption health, team fit, and the signals that justify rollout expansion.",
          modules: [
            "Reading active-repository and usage-depth metrics",
            "What automation acceptance and override trends mean",
            "When to expand from pilot repos to broader repository coverage"
          ]
        },
        {
          key: :platform_admins,
          title: "Platform admins",
          duration: "45 minutes",
          outcome: "Operate tenant-wide defaults, guardrails, and escalation playbooks without bespoke support.",
          modules: [
            "Tenant defaults, feature rollouts, and project autonomy boundaries",
            "Guardrail tuning across concurrency, quality, and budget controls",
            "Reference operating models and production readiness checks"
          ]
        }
      ].freeze

      def self.call(...)
        new(...).call
      end

      def initialize(account:, tenant_setting:)
        @account = account
        @tenant_setting = tenant_setting
      end

      def call
        {
          rollout_stage: rollout_stage,
          metrics: metrics,
          recommendations: recommendations,
          playbooks: PLAYBOOKS,
          training_tracks: training_tracks,
          operating_models: OPERATING_MODELS
        }
      end

      private

      attr_reader :account, :tenant_setting

      def projects
        @projects ||= account.projects.includes(:pre_commit_requirements, :pr_templates).to_a
      end

      def project_ids
        @project_ids ||= projects.map(&:id)
      end

      def recent_runs
        @recent_runs ||= AgentRun.where(project_id: project_ids, created_at: WINDOW_DAYS.days.ago..Time.current)
      end

      def recent_projects
        @recent_projects ||= account.projects.joins(:agent_runs)
          .where(agent_runs: { created_at: WINDOW_DAYS.days.ago..Time.current })
          .distinct
      end

      def active_projects_count
        @active_projects_count ||= recent_projects.count
      end

      def feature_signals
        @feature_signals ||= FEATURE_SIGNALS.map do |signal|
          signal.merge(enabled: feature_enabled?(signal.fetch(:key)))
        end
      end

      def enabled_feature_count
        feature_signals.count { |signal| signal[:enabled] }
      end

      def usage_depth_percentage
        return 0 if feature_signals.empty?

        ((enabled_feature_count / feature_signals.size.to_f) * 100).round
      end

      def automatic_finished_runs
        recent_runs.where(trigger_type: "automatic", status: AgentRun::FINISHED_STATUSES)
      end

      def automation_acceptance_rate
        @automation_acceptance_rate ||= begin
          total = automatic_finished_runs.count
          return nil if total.zero?

          ((automatic_finished_runs.where(status: "completed").count / total.to_f) * 100).round
        end
      end

      def manual_override_rate
        @manual_override_rate ||= begin
          total = recent_runs_count
          return nil if total.zero?

          ((recent_runs.where(trigger_type: "manual").count / total.to_f) * 100).round
        end
      end

      def recent_runs_count
        @recent_runs_count ||= recent_runs.count
      end

      def metrics
        {
          active_repositories: active_projects_count,
          active_projects: active_projects_count,
          usage_depth: {
            enabled: enabled_feature_count,
            total: feature_signals.size,
            percentage: usage_depth_percentage,
            enabled_features: feature_signals.select { |signal| signal[:enabled] }.map { |signal| signal[:label] }
          },
          automation_acceptance_rate: automation_acceptance_rate,
          manual_override_rate: manual_override_rate,
          recent_runs: recent_runs_count
        }
      end

      def rollout_stage
        if projects.empty?
          {
            label: "Setup",
            summary: "No repositories are connected yet. Finish the first production workflow before tuning rollout policy."
          }
        elsif active_projects_count <= 1
          {
            label: "Pilot",
            summary: "A small repository footprint is active. Focus on repeatability, reviewer confidence, and explicit expansion criteria."
          }
        elsif usage_depth_percentage < 60
          {
            label: "Expansion",
            summary: "Multiple repositories are active, but core rollout capabilities are still uneven across the account."
          }
        else
          {
            label: "Operationalized",
            summary: "Paid is active across multiple repositories with enough controls in place to scale with less bespoke support."
          }
        end
      end

      def training_tracks
        TRACKS.map do |track|
          track.merge(status: training_status_for(track.fetch(:key)))
        end
      end

      def training_status_for(track_key)
        case track_key
        when :developers
          active_projects_count.positive? ? "Run now" : "After first repo"
        when :reviewers
          projects.any?(&:review_enabled?) ? "Run now" : "Before enabling automated review"
        when :managers
          recent_runs.exists? ? "Run now" : "After pilot starts"
        when :platform_admins
          "Run now"
        end
      end

      def recommendations
        [
          first_repo_recommendation,
          active_repository_recommendation,
          auto_pick_recommendation,
          review_recommendation,
          guardrail_recommendation,
          quality_gate_recommendation,
          override_recommendation
        ].compact
      end

      def first_repo_recommendation
        return unless projects.empty?

        recommendation(
          severity: :blocker,
          title: "Connect the first rollout repository",
          detail: "Pilot-to-production playbooks are only useful after at least one real repository is running through Paid.",
          action: "Finish onboarding and create the first project."
        )
      end

      def active_repository_recommendation
        return unless projects.any? && active_projects_count.zero?

        recommendation(
          severity: :blocker,
          title: "Drive the first active repository through the pilot",
          detail: "The account has connected repositories but no recent repository activity in the last #{WINDOW_DAYS} days.",
          action: "Pick one repository and run the pilot rollout playbook end to end."
        )
      end

      def auto_pick_recommendation
        return if projects.empty? || projects.any?(&:auto_pick_enabled?)

        recommendation(
          severity: :opportunity,
          title: "Enable auto-pick in at least one pilot project",
          detail: "Manual-only usage slows expansion because teams cannot observe steady-state automation behavior.",
          action: "Start with one well-triaged repository and promote from automation-on-label to auto-pick."
        )
      end

      def review_recommendation
        return if projects.empty? || projects.any?(&:review_enabled?)

        recommendation(
          severity: :opportunity,
          title: "Add an automated review path",
          detail: "Reviewer training is less repeatable when Paid output bypasses a standard review workflow.",
          action: "Configure at least one project with an automated review method before broad rollout."
        )
      end

      def guardrail_recommendation
        return if account_pre_commit_guardrails_enabled? && account_pr_templates_enabled?

        recommendation(
          severity: :blocker,
          title: "Standardize rollout guardrails",
          detail: "Account-level pre-commit requirements and PR templates are still missing, which makes cross-team adoption inconsistent.",
          action: "Define default PR templates and blocking checks at the account level."
        )
      end

      def quality_gate_recommendation
        return if tenant_setting.effective_quality_thresholds["enabled"] == true

        recommendation(
          severity: :opportunity,
          title: "Turn on quality gates before broad expansion",
          detail: "Quality thresholds are still disabled, so platform owners have fewer early warning signals when automation drifts.",
          action: "Enable account-level quality gates once the pilot repositories have stable baselines."
        )
      end

      def override_recommendation
        return unless manual_override_rate.to_i >= 40 && recent_runs_count >= 5

        recommendation(
          severity: :watch,
          title: "Manual override rate is high",
          detail: "#{manual_override_rate}% of recent runs were started manually, which suggests teams still bypass default automation paths.",
          action: "Review trigger patterns with managers and decide which repos are ready for more automation."
        )
      end

      def recommendation(severity:, title:, detail:, action:)
        {
          severity:,
          title:,
          detail:,
          action:
        }
      end

      def feature_enabled?(key)
        case key
        when :auto_pick_rollout
          projects.any?(&:auto_pick_enabled?)
        when :automated_review
          projects.any?(&:review_enabled?)
        when :pre_commit_guardrails
          account_pre_commit_guardrails_enabled? || project_pre_commit_guardrails_enabled?
        when :pr_templates
          account_pr_templates_enabled? || project_pr_templates_enabled?
        when :quality_gates
          tenant_setting.effective_quality_thresholds["enabled"] == true
        when :knowledge_evolution
          projects.any?(&:knowledge_evolution_enabled?)
        when :marketplace_auto_attach
          tenant_setting.marketplace_auto_attach_required?
        end
      end

      def account_pre_commit_guardrails_enabled?
        enabled_association_records?(account, :pre_commit_requirements)
      end

      def project_pre_commit_guardrails_enabled?
        projects.any? { |project| enabled_association_records?(project, :pre_commit_requirements) }
      end

      def account_pr_templates_enabled?
        enabled_association_records?(account, :pr_templates)
      end

      def project_pr_templates_enabled?
        projects.any? { |project| enabled_association_records?(project, :pr_templates) }
      end

      def enabled_association_records?(record, association_name)
        loaded_association_records(record, association_name).any?(&:enabled?)
      end

      def loaded_association_records(record, association_name)
        association = record.association(association_name)
        association.loaded? ? association.target : association.load_target
      end
    end
  end
end
