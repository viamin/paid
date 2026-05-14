# frozen_string_literal: true

require "rails_helper"
require "active_model"

RSpec.describe "strategy_reviews/show", :no_db, type: :view do
  let(:strategy_class) do
    Class.new do
      include ActiveModel::Model
      include ActiveModel::Attributes

      attribute :id, :integer
      attribute :name, :string
      attribute :decision_type, :string
      attr_accessor :current_version

      def persisted? = true
    end
  end
  let(:strategy_version_class) do
    Class.new do
      include ActiveModel::Model
      include ActiveModel::Attributes

      attribute :id, :integer
      attribute :version, :integer
      attribute :change_notes, :string
      attribute :reasoning, :string
      attribute :created_by, :string
      attribute :promotion_state, :string
      attr_accessor :content, :parent_version, :created_by_user

      def persisted? = true

      def pending_review?
        promotion_state == "candidate"
      end
    end
  end
  let(:current_version) do
    strategy_version_class.new(
      id: 1,
      version: 1,
      content: { "mode" => "single" },
      promotion_state: "active"
    )
  end
  let(:strategy_version) do
    strategy_version_class.new(
      id: 2,
      version: 2,
      change_notes: "Candidate update",
      reasoning: "Tighten rollout guardrails",
      content: { "mode" => "parallel" },
      promotion_state: "candidate"
    )
  end
  let(:strategy) do
    strategy_class.new(
      id: 10,
      name: "Issue Execution",
      decision_type: "issue_execution",
      current_version: current_version
    )
  end

  before do
    assign(:strategy, strategy)
    assign(:strategy_version, strategy_version)

    policy_double = instance_double(StrategyPolicy, update?: true)

    view.define_singleton_method(:policy) { |_| policy_double }
    view.define_singleton_method(:back_link_path) { |_path| "/strategies/10/reviews" }
    view.define_singleton_method(:strategy_reviews_path) { |_strategy| "/strategies/10/reviews" }
    view.define_singleton_method(:strategy_review_path) { |_strategy, _version| "/strategies/10/reviews/2" }
    view.define_singleton_method(:approve_strategy_review_path) { |_strategy, _version| "/strategies/10/reviews/2/approve" }
    view.define_singleton_method(:reject_strategy_review_path) { |_strategy, _version| "/strategies/10/reviews/2/reject" }
  end

  it "renders edit fields with the expected strategy_version param names" do
    render

    fragment = Nokogiri::HTML.fragment(rendered)
    form = fragment.at_css(%(form[action="/strategies/10/reviews/2"]))

    expect(form.at_css(%(input[name="strategy_version[change_notes]"]))["type"]).to eq("text")
    expect(form.at_css(%(textarea[name="strategy_version[reasoning]"]))).to be_present
    expect(form.at_css(%(textarea[name="strategy_version[content]"]))).to be_present
  end
end
