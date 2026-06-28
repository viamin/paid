# frozen_string_literal: true

module Billing
  class AdvanceAccountPeriods
    DEFAULT_PAYMENT_TERMS_DAYS = 14

    Result = Struct.new(
      :account_id,
      :closed_period_ids,
      :opened_period_ids,
      :generated_invoice_ids,
      :issued_invoice_ids,
      keyword_init: true
    )

    attr_reader :account, :as_of

    def initialize(account:, as_of: Time.current)
      @account = account
      @as_of = as_of
    end

    def self.call(...)
      new(...).call
    end

    def call
      return empty_result unless active_plan

      ActiveRecord::Base.transaction do
        account.lock!
        close_due_periods
        invoice_closed_periods
        ensure_current_open_period
      end

      result
    end

    private

    def result
      @result ||= Result.new(
        account_id: account.id,
        closed_period_ids: [],
        opened_period_ids: [],
        generated_invoice_ids: [],
        issued_invoice_ids: []
      )
    end

    def empty_result
      Result.new(
        account_id: account.id,
        closed_period_ids: [],
        opened_period_ids: [],
        generated_invoice_ids: [],
        issued_invoice_ids: []
      )
    end

    def active_plan
      @active_plan ||= account.billing_plans.active.order(created_at: :desc).first
    end

    def close_due_periods
      account.billing_periods.open
        .where("ends_at <= ?", as_of)
        .order(:starts_at, :id)
        .each do |period|
          period.close!
          result.closed_period_ids << period.id
        end
    end

    def invoice_closed_periods
      account.billing_periods.where(status: %w[closed invoiced])
        .where("ends_at <= ?", as_of)
        .order(:starts_at, :id)
        .each do |period|
          existing_invoice = period.billing_invoices.order(:created_at, :id).last
          invoice = existing_invoice || GenerateInvoice.call(billing_period: period)
          result.generated_invoice_ids << invoice.id if existing_invoice.nil? && invoice.present?
          issue_invoice(invoice)
        end
    end

    def issue_invoice(invoice)
      return unless invoice&.draft?

      issued_at = Time.current
      invoice.update!(
        status: "issued",
        issued_at: issued_at,
        due_at: invoice.due_at || (invoice.billing_period.ends_at + DEFAULT_PAYMENT_TERMS_DAYS.days),
        metadata: invoice.metadata.merge(
          "payment_sync_status" => invoice.external_id.present? ? "pending" : "not_configured",
          "managed_billing_scope" => "internal_tracking_only",
          "last_issued_at" => issued_at.iso8601
        )
      )
      result.issued_invoice_ids << invoice.id
    end

    def ensure_current_open_period
      return if current_open_period.present?

      starts_at = period_start_for(as_of)
      ends_at = next_period_start_for(starts_at)
      period = account.billing_periods.find_or_initialize_by(starts_at: starts_at, ends_at: ends_at)
      return unless period.new_record?

      period.assign_attributes(
        billing_plan: active_plan,
        period_type: active_plan.period_type,
        status: "open",
        metadata: (period.metadata || {}).merge("opened_by" => "scheduled_billing", "opened_at" => Time.current.iso8601)
      )
      period.save!
      result.opened_period_ids << period.id
    end

    def current_open_period
      account.billing_periods.open.find_by("starts_at <= ? AND ends_at > ?", as_of, as_of)
    end

    def period_start_for(time)
      case active_plan.period_type
      when "daily"
        time.beginning_of_day
      when "weekly"
        time.beginning_of_week
      else
        time.beginning_of_month
      end
    end

    def next_period_start_for(starts_at)
      case active_plan.period_type
      when "daily"
        starts_at + 1.day
      when "weekly"
        starts_at + 1.week
      else
        starts_at.next_month
      end
    end
  end
end
