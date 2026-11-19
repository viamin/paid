# frozen_string_literal: true

require "rails_helper"

RSpec.describe OperatorConsole::RequestContext, :no_db, type: :controller do
  request_context = described_class

  controller(ActionController::Base) do
    include request_context

    before_action :capture_request_context

    attr_reader :bypass_enabled_during_before_action, :current_user_during_before_action

    def index
      head :ok
    end

    def explode
      raise "boom"
    end

    def current_user
      Struct.new(:id, :email).new(7, "operator@example.com")
    end

    private

    def capture_request_context
      @bypass_enabled_during_before_action = TenantContext.bypass_enabled?
      @current_user_during_before_action = Current.user
    end
  end

  # Rails' executor establishes the test harness's system-access baseline before
  # controller callbacks run. RequestContext must preserve that baseline after
  # its temporary request setup, including when the action raises.
  let(:system_access_state) { { enabled: true } }

  before do
    allow(TenantContext).to receive(:apply_system_access!) do
      system_access_state[:enabled] = true
      Current.account = nil
    end
    allow(TenantContext).to receive(:restore!) do |account:, bypass:|
      Current.account = account
      system_access_state[:enabled] = bypass
    end
    allow(TenantContext).to receive(:bypass_enabled?) { system_access_state[:enabled] }

    routes.draw do
      get "index" => "anonymous#index"
      get "explode" => "anonymous#explode"
    end
  end

  # @spec POSTGRESQL-PERSISTENCE-002
  it "applies system access before downstream callbacks and restores request state afterward" do
    get :index

    expect(response).to have_http_status(:ok)
    expect(controller.bypass_enabled_during_before_action).to be(true)
    expect(controller.current_user_during_before_action.email).to eq("operator@example.com")
    expect(TenantContext.bypass_enabled?).to be(true)
    expect(Current.user).to be_nil
    expect(Current.account).to be_nil
    expect(TenantContext).to have_received(:restore!).with(account: nil, bypass: true)
  end

  # @spec POSTGRESQL-PERSISTENCE-002
  it "restores request state when the action raises" do
    expect { get :explode }.to raise_error(RuntimeError, "boom")

    expect(Current.user).to be_nil
    expect(Current.account).to be_nil
    expect(TenantContext.bypass_enabled?).to be(true)
    expect(TenantContext).to have_received(:restore!).with(account: nil, bypass: true)
  end
end
