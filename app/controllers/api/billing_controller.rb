# frozen_string_literal: true

module Api
  class BillingController < ApplicationController
    RATE_LIMIT_MAX_REQUESTS = 60
    RATE_LIMIT_PERIOD = 1.minute

    rate_limit to: RATE_LIMIT_MAX_REQUESTS, within: RATE_LIMIT_PERIOD,
      by: -> { current_user&.id },
      with: -> { render json: { error: "Rate limit exceeded" }, status: :too_many_requests }

    rescue_from ActiveRecord::RecordNotFound do
      render json: { error: "Not found" }, status: :not_found
    end

    rescue_from Pundit::NotAuthorizedError do
      render json: { error: "Forbidden" }, status: :forbidden
    end

    # GET /api/billing/usage?starts_at=...&ends_at=...
    def usage
      authorize current_account, :billing?, policy_class: BillingPolicy

      starts_at = parse_time(params[:starts_at]) || 30.days.ago
      ends_at = parse_time(params[:ends_at]) || Time.current

      result = Billing::AggregateTenantUsage.call(
        account: current_account,
        starts_at: starts_at,
        ends_at: ends_at
      )

      render json: result
    end

    # GET /api/billing/periods
    def periods
      authorize current_account, :billing?, policy_class: BillingPolicy

      periods = current_account.billing_periods
        .order(starts_at: :desc)
        .limit(params.fetch(:limit, 12).to_i.clamp(1, 100))

      render json: periods.map { |p| period_json(p) }
    end

    # GET /api/billing/periods/:id
    def show_period
      authorize current_account, :billing?, policy_class: BillingPolicy

      period = current_account.billing_periods.find(params[:id])
      render json: period_json(period).merge(metadata: period.metadata)
    end

    # GET /api/billing/invoices
    def invoices
      authorize current_account, :billing?, policy_class: BillingPolicy

      invoices = current_account.billing_invoices
        .includes(:billing_line_items)
        .order(created_at: :desc)
        .limit(params.fetch(:limit, 12).to_i.clamp(1, 100))

      render json: invoices.map { |inv| invoice_json(inv) }
    end

    # GET /api/billing/invoices/:id
    def show_invoice
      authorize current_account, :billing?, policy_class: BillingPolicy

      invoice = current_account.billing_invoices.includes(:billing_line_items).find(params[:id])
      render json: invoice_json(invoice).merge(
        line_items: invoice.billing_line_items.map { |li| line_item_json(li) }
      )
    end

    # GET /api/billing/plan
    def plan
      authorize current_account, :billing?, policy_class: BillingPolicy

      active_plan = current_account.billing_plans.active.order(created_at: :desc).first

      if active_plan
        render json: plan_json(active_plan)
      else
        render json: { plan: nil }
      end
    end

    private

    def current_account
      current_user.account
    end

    def authenticate_user!
      return if user_signed_in?

      render json: { error: "Unauthorized" }, status: :unauthorized
    end

    def parse_time(value)
      return nil if value.blank?

      Time.zone.parse(value)
    rescue ArgumentError
      nil
    end

    def period_json(period)
      {
        id: period.id,
        period_type: period.period_type,
        starts_at: period.starts_at.iso8601,
        ends_at: period.ends_at.iso8601,
        status: period.status,
        total_cost_cents: period.total_cost_cents,
        total_input_tokens: period.total_input_tokens,
        total_output_tokens: period.total_output_tokens,
        total_runs: period.total_runs,
        total_compute_seconds: period.total_compute_seconds
      }
    end

    def invoice_json(invoice)
      {
        id: invoice.id,
        external_id: invoice.external_id,
        status: invoice.status,
        subtotal_cents: invoice.subtotal_cents,
        tax_cents: invoice.tax_cents,
        total_cents: invoice.total_cents,
        issued_at: invoice.issued_at&.iso8601,
        due_at: invoice.due_at&.iso8601,
        paid_at: invoice.paid_at&.iso8601
      }
    end

    def line_item_json(li)
      {
        id: li.id,
        description: li.description,
        line_item_type: li.line_item_type,
        quantity: li.quantity.to_f,
        unit_price_cents: li.unit_price_cents,
        total_cents: li.total_cents
      }
    end

    def plan_json(plan)
      {
        id: plan.id,
        name: plan.name,
        billing_model: plan.billing_model,
        period_type: plan.period_type,
        base_rate_cents: plan.base_rate_cents,
        per_token_rate_cents: plan.per_token_rate_cents.to_f,
        per_run_rate_cents: plan.per_run_rate_cents,
        per_project_rate_cents: plan.per_project_rate_cents,
        included_tokens: plan.included_tokens,
        included_runs: plan.included_runs,
        included_projects: plan.included_projects,
        active: plan.active
      }
    end
  end
end
