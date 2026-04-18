# frozen_string_literal: true

require "rails_helper"

RSpec.describe ApplicationHelper do
  describe "#back_link_path" do
    let(:default_path) { "/projects" }

    context "when params[:return_to] is a valid internal path" do
      it "returns the return_to path" do
        allow(helper).to receive(:params).and_return(ActionController::Parameters.new(return_to: "/agent_runs"))
        allow(helper.request).to receive(:referer).and_return(nil)

        expect(helper.back_link_path(default_path)).to eq("/agent_runs")
      end

      it "accepts paths with query strings" do
        allow(helper).to receive(:params).and_return(ActionController::Parameters.new(return_to: "/agent_runs?status=running"))
        allow(helper.request).to receive(:referer).and_return(nil)

        expect(helper.back_link_path(default_path)).to eq("/agent_runs?status=running")
      end
    end

    context "when params[:return_to] is unsafe" do
      it "rejects external URLs" do
        allow(helper).to receive(:params).and_return(ActionController::Parameters.new(return_to: "https://evil.com/steal"))
        allow(helper.request).to receive(:referer).and_return(nil)

        expect(helper.back_link_path(default_path)).to eq(default_path)
      end

      it "rejects protocol-relative URLs" do
        allow(helper).to receive(:params).and_return(ActionController::Parameters.new(return_to: "//evil.com/steal"))
        allow(helper.request).to receive(:referer).and_return(nil)

        expect(helper.back_link_path(default_path)).to eq(default_path)
      end
    end

    context "when return_to is absent but referer is a same-host URL" do
      it "returns the referer" do
        allow(helper).to receive(:params).and_return(ActionController::Parameters.new({}))
        allow(helper.request).to receive_messages(referer: "http://test.host/agent_runs", host: "test.host")

        expect(helper.back_link_path(default_path)).to eq("http://test.host/agent_runs")
      end
    end

    context "when referer is from a different host" do
      it "falls back to default" do
        allow(helper).to receive(:params).and_return(ActionController::Parameters.new({}))
        allow(helper.request).to receive_messages(referer: "https://other.com/page", host: "test.host")

        expect(helper.back_link_path(default_path)).to eq(default_path)
      end
    end

    context "when neither return_to nor referer is available" do
      it "returns the default path" do
        allow(helper).to receive(:params).and_return(ActionController::Parameters.new({}))
        allow(helper.request).to receive(:referer).and_return(nil)

        expect(helper.back_link_path(default_path)).to eq(default_path)
      end
    end

    context "when both return_to and referer are present" do
      it "uses return_to over referer" do
        allow(helper).to receive(:params).and_return(ActionController::Parameters.new(return_to: "/specific_page"))
        allow(helper.request).to receive_messages(referer: "http://test.host/other_page", host: "test.host")

        expect(helper.back_link_path(default_path)).to eq("/specific_page")
      end
    end
  end
end
