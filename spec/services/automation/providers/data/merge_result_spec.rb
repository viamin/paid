# frozen_string_literal: true

require "rails_helper"

RSpec.describe Automation::Providers::Data::MergeResult do
  it "captures whether the merge happened, with an optional sha" do
    result = described_class.new(merged: true, sha: "abc", message: "ok")
    expect(result.merged).to be(true)
    expect(result.sha).to eq("abc")
  end
end
