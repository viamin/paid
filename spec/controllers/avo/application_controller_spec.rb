# frozen_string_literal: true

require "rails_helper"

RSpec.describe Avo::ApplicationController, :no_db do
  subject(:authenticate) { Avo.configuration.authenticate }

  let(:operator_user) { Struct.new(:operator?).new(true) }
  let(:non_operator_user) { Struct.new(:operator?).new(false) }
  let(:warden) { instance_double(Warden::Proxy, authenticate: authenticated_user) }
  let(:paths) { Struct.new(:new_user_session_path, :root_path).new("/users/sign_in", "/") }
  let(:controller_context) do
    Class.new do
      attr_reader :redirect_path, :redirect_options

      def initialize(warden:, paths:)
        @warden = warden
        @paths = paths
      end

      def warden
        @warden
      end

      def main_app
        @paths
      end

      def redirect_to(path, **options)
        @redirect_path = path
        @redirect_options = options
      end
    end.new(warden:, paths:)
  end

  context "when the request is unauthenticated" do
    let(:authenticated_user) { nil }

    it "redirects to sign in" do
      controller_context.instance_exec(&authenticate)

      expect(controller_context.redirect_path).to eq("/users/sign_in")
      expect(controller_context.redirect_options).to eq({})
    end
  end

  context "when the user is signed in but not an operator" do
    let(:authenticated_user) { non_operator_user }

    it "redirects to the app root with an authorization alert" do
      controller_context.instance_exec(&authenticate)

      expect(controller_context.redirect_path).to eq("/")
      expect(controller_context.redirect_options).to eq(
        { alert: "You are not authorized to access the operator console." }
      )
    end
  end

  context "when the user is an operator" do
    let(:authenticated_user) { operator_user }

    it "allows the request to continue" do
      controller_context.instance_exec(&authenticate)

      expect(controller_context.redirect_path).to be_nil
      expect(controller_context.redirect_options).to be_nil
    end
  end
end
