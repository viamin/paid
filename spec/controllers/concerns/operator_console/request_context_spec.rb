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

    def current_user
      Struct.new(:id, :email).new(7, "operator@example.com")
    end

    private

    def capture_request_context
      @bypass_enabled_during_before_action = TenantContext.bypass_enabled?
      @current_user_during_before_action = Current.user
    end
  end

  let(:system_access_state) { { enabled: false } }

  before do
    allow(TenantContext).to receive(:apply_system_access!) do
      system_access_state[:enabled] = true
      Current.account = nil
    end
    allow(TenantContext).to receive(:clear!) do
      system_access_state[:enabled] = false
      Current.account = nil
    end
    allow(TenantContext).to receive(:bypass_enabled?) { system_access_state[:enabled] }

    routes.draw { get "index" => "anonymous#index" }
  end

  it "applies system access before downstream callbacks and clears request state afterward" do
    get :index

    expect(response).to have_http_status(:ok)
    expect(controller.bypass_enabled_during_before_action).to be(true)
    expect(controller.current_user_during_before_action.email).to eq("operator@example.com")
    expect(TenantContext.bypass_enabled?).to be(false)
    expect(Current.user).to be_nil
    expect(Current.account).to be_nil
  end
end
