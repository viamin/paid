# frozen_string_literal: true

module Api
  class KnowledgeQualityController < ApplicationController
    MIN_SEVERITIES = %w[info warning error].freeze
    MIN_SEVERITY_RANK = MIN_SEVERITIES.each_with_index.to_h.freeze
    RATE_LIMIT_MAX_REQUESTS = 20
    RATE_LIMIT_PERIOD = 1.minute

    # Report generation is strictly more expensive than semantic search
    # (13 checks, aggregate queries, and — in the HTML view — a git subprocess),
    # so this endpoint carries its own rate-limit guard tuned lower than the
    # sibling search controller.
    rate_limit to: RATE_LIMIT_MAX_REQUESTS, within: RATE_LIMIT_PERIOD,
      by: -> { current_user&.id },
      with: -> { render json: { error: "Rate limit exceeded" }, status: :too_many_requests }

    rescue_from ActiveRecord::RecordNotFound do
      render json: { error: "Project not found" }, status: :not_found
    end

    rescue_from Pundit::NotAuthorizedError do
      render json: { error: "Forbidden" }, status: :forbidden
    end

    # GET /api/knowledge/quality?project_id=X&min_severity=warning
    def show
      @project = TenantContext.with_system_access { Project.find(params[:project_id]) }
      authorize @project, :search?, policy_class: KnowledgeSearchPolicy

      min_severity = params[:min_severity].presence
      if min_severity && !MIN_SEVERITIES.include?(min_severity)
        return render json: {
          error: "min_severity must be one of: #{MIN_SEVERITIES.join(", ")}"
        }, status: :bad_request
      end

      report = Knowledge::Quality::Lint.call(project: @project)
      if min_severity
        report[:findings] = filter_findings(report[:findings], min_severity)
        # Recompute so summary counts match the filtered findings array, not
        # the unfiltered report. Note that per-check truncation happens
        # inside Lint before filtering — with a large project it's possible
        # for error-severity findings to be dropped by the per-check cap
        # after being crowded out by lower-severity findings from the same
        # check. `truncated_checks` still reports which checks were capped.
        report[:summary] = Knowledge::Quality::Lint.summarize(report[:findings])
      end
      render json: report
    end

    private

    def filter_findings(findings, min_severity)
      threshold = MIN_SEVERITY_RANK[min_severity]
      findings.select { |finding| MIN_SEVERITY_RANK[finding[:severity]] >= threshold }
    end

    # Override Devise redirect to return JSON 401 for this API endpoint.
    def authenticate_user!
      return if user_signed_in?

      render json: { error: "Unauthorized" }, status: :unauthorized
    end
  end
end
