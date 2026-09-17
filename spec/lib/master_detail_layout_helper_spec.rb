# frozen_string_literal: true

require "rails_helper"

# Unit coverage of the shared layout rules in `MasterDetailLayoutHelper`.
# Specs here are deliberately narrow: they assert the constants and class
# strings the helper exposes so a future tweak to the shared rule stays a
# single edit and stays aligned with the shared partial and the per-feature
# views that consume it. Visual behavior — that the Inbox and Chat pages
# actually render through the shared shell with these classes — is covered
# by `spec/system/dashboard_inbox_spec.rb` and `spec/system/chat_layout_spec.rb`.
#
# @spec LIST-DETAIL-001 @spec LIST-DETAIL-002 @spec LIST-DETAIL-004
RSpec.describe MasterDetailLayoutHelper, type: :helper do
  describe "shared structural constants" do
    # @spec LIST-DETAIL-001 @spec LIST-DETAIL-004
    it "pins the split-pane breakpoint to Tailwind's lg breakpoint (1024px)" do
      expect(MasterDetailLayoutHelper::MASTER_DETAIL_BREAKPOINT_PX).to eq(1024)
    end

    # @spec LIST-DETAIL-001 @spec LIST-DETAIL-004
    it "pins the list pane width at 22rem so both screens match" do
      expect(MasterDetailLayoutHelper::MASTER_DETAIL_LIST_PANE_WIDTH).to eq("22rem")
    end
  end

  describe "shared class strings" do
    # @spec LIST-DETAIL-001 @spec LIST-DETAIL-004
    it "exposes a single grid class string with the shared template and gap-6 spacing" do
      helper = Class.new { include MasterDetailLayoutHelper }.new

      expect(helper.master_detail_grid_classes).to eq("grid gap-6 lg:grid-cols-[22rem,1fr]")
    end

    # @spec LIST-DETAIL-002 @spec LIST-DETAIL-004
    it "exposes a single pane-card chrome so the list and detail halves read as one card" do
      helper = Class.new { include MasterDetailLayoutHelper }.new

      expect(helper.master_detail_pane_classes).to eq(
        "overflow-hidden rounded-xl border border-gray-200 bg-white shadow-sm"
      )
    end

    # @spec LIST-DETAIL-003 @spec LIST-DETAIL-004
    it "exposes a single selected-row class set so both screens render the same active state" do
      helper = Class.new { include MasterDetailLayoutHelper }.new

      expect(helper.master_detail_active_row_classes).to eq("bg-indigo-50 ring-1 ring-inset ring-indigo-200")
    end

    # @spec LIST-DETAIL-002 @spec LIST-DETAIL-004
    it "exposes a single empty-state chrome so the no-selection card matches the populated card" do
      helper = Class.new { include MasterDetailLayoutHelper }.new

      expect(helper.master_detail_empty_state_classes).to eq(
        "rounded-xl border border-dashed border-gray-300 bg-white px-6 py-12 text-center shadow-sm"
      )
    end
  end

  describe "shared partials" do
    # @spec LIST-DETAIL-005
    it "renders the two-pane grid through app/views/shared/_list_detail_shell.html.erb" do
      view = Class.new do
        include MasterDetailLayoutHelper
        include ActionView::Helpers::TagHelper
      end.new

      shell_path = Rails.root.join("app/views/shared/_list_detail_shell.html.erb").to_s
      expect(File.exist?(shell_path)).to be(true), "expected #{shell_path} to exist"
      expect(shell_path).to end_with("_list_detail_shell.html.erb")
      expect(view.master_detail_grid_classes).to include("lg:grid-cols-[")
    end

    # @spec LIST-DETAIL-002 @spec LIST-DETAIL-005
    it "renders the empty-state chrome through app/views/shared/_list_detail_empty_state.html.erb" do
      empty_state_path = Rails.root.join("app/views/shared/_list_detail_empty_state.html.erb").to_s
      expect(File.exist?(empty_state_path)).to be(true), "expected #{empty_state_path} to exist"
    end
  end

  describe "consumer coverage" do
    # @spec LIST-DETAIL-006
    it "is reachable from Inbox's master-detail Stimulus controller's row links" do
      inbox_list_path = Rails.root.join("app/views/dashboard/_inbox_list.html.erb").to_s
      inbox_list = File.read(inbox_list_path)

      expect(inbox_list).to include("master_detail_active_row_classes")
      expect(inbox_list).to include("active_classes")
    end

    # @spec LIST-DETAIL-003 @spec LIST-DETAIL-006
    it "is reachable from Chat's session-card Stimulus controller" do
      session_card_path = Rails.root.join("app/views/chat_sessions/_session_card.html.erb").to_s
      session_card = File.read(session_card_path)

      expect(session_card).to include("master_detail_active_row_classes")
      expect(session_card).to include("active_classes")
    end

    # @spec LIST-DETAIL-001 @spec LIST-DETAIL-006
    it "renders the Inbox page through the shared shell" do
      inbox_index_path = Rails.root.join("app/views/inbox/index.html.erb").to_s
      inbox_index = File.read(inbox_index_path)

      expect(inbox_index).to include('render "shared/list_detail_shell"')
    end

    # @spec LIST-DETAIL-001 @spec LIST-DETAIL-006
    it "renders the Chat sessions pages through the shared shell" do
      chat_index_path = Rails.root.join("app/views/chat_sessions/index.html.erb").to_s
      chat_show_path = Rails.root.join("app/views/chat_sessions/show.html.erb").to_s

      expect(File.read(chat_index_path)).to include('render "shared/list_detail_shell"')
      expect(File.read(chat_show_path)).to include('render "shared/list_detail_shell"')
    end
  end
end
