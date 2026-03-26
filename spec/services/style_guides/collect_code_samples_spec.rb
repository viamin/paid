# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe StyleGuides::CollectCodeSamples do
  let(:project) { create(:project) }
  let(:github_client) { instance_double(GithubClient) }

  before do
    allow(project.github_token).to receive(:client).and_return(github_client)
  end

  describe ".call" do
    let(:tree_response) do
      OpenStruct.new(tree: tree_items)
    end

    let(:tree_items) do
      [
        OpenStruct.new(type: "blob", path: "app/models/user.rb", size: 500),
        OpenStruct.new(type: "blob", path: "app/services/auth.rb", size: 300),
        OpenStruct.new(type: "blob", path: "src/index.ts", size: 400),
        OpenStruct.new(type: "tree", path: "app/models", size: 0),
        OpenStruct.new(type: "blob", path: "vendor/bundle/gem.rb", size: 200),
        OpenStruct.new(type: "blob", path: "README.md", size: 100),
        OpenStruct.new(type: "blob", path: "tiny.rb", size: 10)
      ]
    end

    let(:ruby_content) do
      OpenStruct.new(content: Base64.strict_encode64("class User\nend"))
    end

    let(:ts_content) do
      OpenStruct.new(content: Base64.strict_encode64("export const foo = 1;"))
    end

    before do
      allow(github_client).to receive(:tree).and_return(tree_response)
      allow(github_client).to receive(:contents).with(project.full_name, path: "app/models/user.rb").and_return(ruby_content)
      allow(github_client).to receive(:contents).with(project.full_name, path: "app/services/auth.rb").and_return(ruby_content)
      allow(github_client).to receive(:contents).with(project.full_name, path: "src/index.ts").and_return(ts_content)
    end

    it "returns samples grouped by language" do
      result = described_class.call(project: project)

      expect(result.keys).to contain_exactly("ruby", "typescript")
      expect(result["ruby"].length).to eq(2)
      expect(result["typescript"].length).to eq(1)
    end

    it "excludes vendor directories" do
      result = described_class.call(project: project)

      paths = result.values.flatten.map { |s| s[:path] }
      expect(paths).not_to include("vendor/bundle/gem.rb")
    end

    it "excludes non-source files" do
      result = described_class.call(project: project)

      paths = result.values.flatten.map { |s| s[:path] }
      expect(paths).not_to include("README.md")
    end

    it "excludes files smaller than 50 bytes" do
      result = described_class.call(project: project)

      paths = result.values.flatten.map { |s| s[:path] }
      expect(paths).not_to include("tiny.rb")
    end

    it "returns empty hash when tree fetch fails" do
      allow(github_client).to receive(:tree).and_raise(GithubClient::Error)

      result = described_class.call(project: project)

      expect(result).to eq({})
    end

    it "skips files that fail to fetch" do
      allow(github_client).to receive(:contents).with(project.full_name, path: "app/models/user.rb").and_raise(GithubClient::NotFoundError)

      result = described_class.call(project: project)

      ruby_paths = result["ruby"].map { |s| s[:path] }
      expect(ruby_paths).to eq([ "app/services/auth.rb" ])
    end
  end
end
