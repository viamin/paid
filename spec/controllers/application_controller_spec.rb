# frozen_string_literal: true

require "rails_helper"

RSpec.describe ApplicationController, type: :controller do
  controller do
    def index
      raise "request failed"
    end
  end

  before do
    routes.draw { get "index" => "anonymous#index" }
    allow(controller).to receive_messages(authenticate_user!: true, current_user: user)
  end

  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }

  it "clears tenant context when an exception escapes the request" do
    expect { get :index }.to raise_error(RuntimeError, "request failed")

    expect(Current.account).to be_nil
    expect(current_account_id).to be_blank
  end

  def current_account_id
    ActiveRecord::Base.connection.select_value("SELECT current_setting('paid.current_account_id', true)")
  end
end
