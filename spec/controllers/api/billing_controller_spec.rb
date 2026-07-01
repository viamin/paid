# frozen_string_literal: true

require "rails_helper"

RSpec.describe Api::BillingController, type: :request do
  let(:account) { create(:account) }
  let(:user) { create(:user, :admin, account: account) }

  before do
    sign_in user
  end

  describe "GET /api/billing/usage" do
    let(:github_token) { create(:github_token, account: account) }
    let(:project) { create(:project, account: account, github_token: github_token) }

    before do
      agent_run = create(:agent_run, :running, project: project)
      create(:token_usage, agent_run: agent_run, input_tokens: 1000, output_tokens: 500,
             cost_cents: 10, request_type: "agent")
    end

    it "returns aggregated usage data" do
      get "/api/billing/usage"

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["account_id"]).to eq(account.id)
      expect(body["token_usage"]["total_cost_cents"]).to eq(10)
    end

    it "accepts time range parameters" do
      get "/api/billing/usage", params: {
        starts_at: 1.week.ago.iso8601,
        ends_at: Time.current.iso8601
      }

      expect(response).to have_http_status(:ok)
    end

    it "returns 401 for unauthenticated requests" do
      sign_out user
      get "/api/billing/usage"

      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 403 for non-admin users" do
      viewer = create(:user, account: account)
      sign_in viewer

      get "/api/billing/usage"

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "GET /api/billing/periods" do
    before do
      plan = create(:billing_plan, account: account)
      create(:billing_period, account: account, billing_plan: plan,
             starts_at: 1.month.ago, ends_at: Time.current)
    end

    it "returns billing periods" do
      get "/api/billing/periods"

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body.length).to eq(1)
      expect(body.first).to include("id", "period_type", "starts_at", "ends_at", "status")
    end
  end

  describe "GET /api/billing/periods/:id" do
    it "returns a specific billing period" do
      plan = create(:billing_plan, account: account)
      period = create(:billing_period, account: account, billing_plan: plan,
                       starts_at: 1.month.ago, ends_at: Time.current)

      get "/api/billing/periods/#{period.id}"

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["id"]).to eq(period.id)
      expect(body).to include("metadata")
    end

    it "returns 404 for periods from other accounts" do
      other_account = create(:account)
      other_plan = create(:billing_plan, account: other_account)
      other_period = create(:billing_period, account: other_account, billing_plan: other_plan,
                             starts_at: 1.month.ago, ends_at: Time.current)

      get "/api/billing/periods/#{other_period.id}"

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /api/billing/invoices" do
    before do
      plan = create(:billing_plan, account: account)
      period = create(:billing_period, account: account, billing_plan: plan,
                       starts_at: 1.month.ago, ends_at: Time.current)
      create(:billing_invoice, account: account, billing_period: period)
    end

    it "returns invoices" do
      get "/api/billing/invoices"

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body.length).to eq(1)
      expect(body.first).to include("id", "status", "total_cents", "payment_sync_status", "payment_provider")
    end
  end

  describe "GET /api/billing/invoices/:id" do
    it "returns invoice with line items" do
      plan = create(:billing_plan, account: account)
      period = create(:billing_period, account: account, billing_plan: plan,
                       starts_at: 1.month.ago, ends_at: Time.current)
      invoice = create(:billing_invoice, account: account, billing_period: period)
      create(:billing_line_item, billing_invoice: invoice)

      get "/api/billing/invoices/#{invoice.id}"

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["id"]).to eq(invoice.id)
      expect(body["line_items"].length).to eq(1)
    end
  end

  describe "GET /api/billing/plan" do
    it "returns the active billing plan" do
      create(:billing_plan, account: account, name: "Pro Plan")

      get "/api/billing/plan"

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["name"]).to eq("Pro Plan")
    end

    it "returns null plan when no active plan exists" do
      get "/api/billing/plan"

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["plan"]).to be_nil
    end
  end
end
