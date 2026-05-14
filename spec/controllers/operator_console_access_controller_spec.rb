# frozen_string_literal: true

require "rails_helper"

RSpec.describe OperatorConsoleAccessController, :no_db, type: :controller do
  let(:non_operator_user) do
    Struct.new(:id, :email, :operator?, :account).new(42, "owner@example.com", false, nil)
  end

  before do
    routes.draw do
      root to: "dashboard#show"
      match "show" => "operator_console_access#show", via: :all
    end
    allow(controller).to receive(:with_current_attributes).and_yield
  end

  it "redirects anonymous users to sign in" do
    allow(controller).to receive(:authenticate_user!) { controller.redirect_to("/users/sign_in") }

    get :show

    expect(response).to redirect_to("/users/sign_in")
  end

  it "denies an account owner without operator access" do
    allow(controller).to receive_messages(authenticate_user!: true, current_user: non_operator_user)

    get :show

    expect(response).to redirect_to("/")
    expect(flash[:alert]).to eq("You are not authorized to access the operator console.")
  end

  it "denies an account admin without operator access" do
    admin_user = Struct.new(:id, :email, :operator?, :account).new(84, "admin@example.com", false, nil)
    allow(controller).to receive_messages(authenticate_user!: true, current_user: admin_user)

    get :show

    expect(response).to redirect_to("/")
    expect(flash[:alert]).to eq("You are not authorized to access the operator console.")
  end
end
