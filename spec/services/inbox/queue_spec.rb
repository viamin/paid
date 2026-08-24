# frozen_string_literal: true

require "rails_helper"

RSpec.describe Inbox::Queue do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) do
    create(:project, account: account, created_by: user, auto_pick_enabled: true, active: true, owner: "acme", repo: "alpha")
  end
  let(:questions_body) do
    <<~BODY
      <!-- paid:enhance-issue -->

      ## Clarifying questions
      1. What is the expected behavior?
    BODY
  end

  def create_needs_input(overrides = {})
    defaults = { project: project, github_number: 10 }
    create(:issue, :needs_input, **(defaults.merge(overrides)))
  end

  # @spec INBOX-FOUNDATION-003 @spec INBOX-FOUNDATION-004
  # @spec INBOX-FOUNDATION-005 @spec INBOX-FOUNDATION-006
  describe ".call" do
    it "returns typed entries with the :clarifying_questions kind" do
      issue = create_needs_input(body: questions_body)

      entries = described_class.call(user: user, project: project)

      expect(entries.size).to eq(1)
      entry = entries.first
      expect(entry.kind).to eq(:clarifying_questions)
      expect(entry.project).to eq(project)
      expect(entry.issue).to eq(issue)
      expect(entry.questions).to eq([ "What is the expected behavior?" ])
      expect(entry.waiting_since).to be_present
    end

    it "exposes waiting_since from needs_input_since so a future inbox UI can show \"waiting Xh\"" do
      stamp = 2.days.ago
      create_needs_input(body: questions_body).update_columns(needs_input_since: stamp)

      entry = described_class.call(user: user, project: project).first

      expect(entry.waiting_since).to be_within(1.second).of(stamp)
    end

    it "uses locally persisted needs_input_questions for create_feature issues" do
      feature_issue = create_needs_input(
        github_number: 20,
        body: "Need dark mode",
        needs_input_questions: [
          "What is the desired behavior?",
          "What constraints must be respected?"
        ]
      )

      entries = described_class.call(user: user, project: project)

      feature_entry = entries.find { |entry| entry.issue == feature_issue }
      expect(feature_entry.questions).to eq([
        "What is the desired behavior?",
        "What constraints must be respected?"
      ])
    end

    it "skips questionless issues (repaired during sync)" do
      questionless = create_needs_input(github_number: 9, body: "Needs manual retry")
      answerable = create_needs_input(github_number: 10, body: questions_body)

      entries = described_class.call(user: user, project: project)

      expect(entries.map(&:issue)).to contain_exactly(answerable)
      expect(entries.map(&:issue)).not_to include(questionless)
    end
  end

  describe "ordering" do
    # @spec INBOX-FOUNDATION-004
    it "orders oldest-waiting-first by needs_input_since, NULLS LAST" do
      newest = create_needs_input(github_number: 30, body: questions_body)
      oldest = create_needs_input(github_number: 10, body: questions_body)
      middle = create_needs_input(github_number: 20, body: questions_body)
      newest.update_columns(needs_input_since: 1.hour.ago)
      oldest.update_columns(needs_input_since: 3.hours.ago)
      middle.update_columns(needs_input_since: 2.hours.ago)

      order = described_class.call(user: user, project: project).map(&:issue)

      expect(order).to eq([ oldest, middle, newest ])
    end

    it "sorts rows with NULL needs_input_since after rows with a timestamp" do
      with_time = create_needs_input(github_number: 20, body: questions_body)
      without_time = create_needs_input(github_number: 10, body: questions_body)
      with_time.update_columns(needs_input_since: 2.hours.ago)
      without_time.update_columns(needs_input_since: nil)

      order = described_class.call(user: user, project: project).map(&:issue)

      expect(order).to eq([ with_time, without_time ])
    end

    it "tiebreaks by (owner, repo, github_number, id) when needs_input_since is identical" do
      same_time = Time.current
      first = create_needs_input(github_number: 30, body: questions_body)
      second = create_needs_input(github_number: 10, body: questions_body)
      third = create_needs_input(github_number: 20, body: questions_body)
      [ first, second, third ].each { |i| i.update_columns(needs_input_since: same_time) }

      order = described_class.call(user: user, project: project).map(&:issue)

      expect(order).to eq([ second, third, first ])
    end
  end

  describe "including PRs" do
    # @spec INBOX-FOUNDATION-005
    it "includes pull requests alongside issues (drops the is_pull_request: false filter)" do
      issue = create_needs_input(github_number: 10, body: questions_body)
      pr = create(:issue, :needs_input, :pull_request, project: project, github_number: 20, body: questions_body)

      entries = described_class.call(user: user, project: project)

      expect(entries.map(&:issue)).to contain_exactly(issue, pr)
    end
  end

  describe "scoping" do
    # @spec INBOX-FOUNDATION-006
    it "only returns entries from auto-pick projects" do
      other_project = create(:project, account: account, created_by: user, auto_pick_enabled: false, active: true)
      in_scope = create_needs_input(github_number: 10, body: questions_body)
      out_of_scope = create_needs_input(github_number: 20, project: other_project, body: questions_body)

      entries = described_class.call(user: user)

      expect(entries.map(&:issue)).to include(in_scope)
      expect(entries.map(&:issue)).not_to include(out_of_scope)
    end

    it "narrows to a single project when project: is provided" do
      scoped = create_needs_input(github_number: 10, body: questions_body)
      create_needs_input(
        github_number: 11,
        project: create(:project, account: account, created_by: user, auto_pick_enabled: true, active: true),
        body: questions_body
      )

      entries = described_class.call(user: user, project: project)

      expect(entries.map(&:issue)).to contain_exactly(scoped)
    end

    it "excludes projects from other accounts" do
      other_user = create(:user, account: create(:account))
      other_account_project = create(:project, account: other_user.account, created_by: other_user, auto_pick_enabled: true, active: true)
      create_needs_input(github_number: 20, project: other_account_project, body: questions_body)
      mine = create_needs_input(github_number: 10, body: questions_body)

      entries = described_class.call(user: user)

      expect(entries.map(&:issue)).to contain_exactly(mine)
    end
  end
end
