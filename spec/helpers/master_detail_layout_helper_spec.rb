# frozen_string_literal: true

require "rails_helper"

# Unit coverage of the shared layout rules in `MasterDetailLayoutHelper`
# and the shared `_list_detail_shell` partial that consumes them. Specs
# here are deliberately narrow: they assert the class strings the helper
# exposes and the shell's rendered output, so a future tweak to a shared
# rule stays a single edit. That Inbox and Chat actually render through
# the shared shell is behavioral coverage owned by
# `spec/requests/inbox_spec.rb`, `spec/system/dashboard_inbox_spec.rb`,
# and `spec/system/chat_shared_layout_spec.rb`.
#
# @spec LIST-DETAIL-001 @spec LIST-DETAIL-002 @spec LIST-DETAIL-004
# @spec LIST-DETAIL-005
RSpec.describe MasterDetailLayoutHelper do
  describe "shared structural constants" do
    # @spec LIST-DETAIL-001 @spec LIST-DETAIL-004
    it "pins the list pane width at 22rem so both screens match" do
      expect(MasterDetailLayoutHelper::MASTER_DETAIL_LIST_PANE_WIDTH).to eq("22rem")
    end
  end

  describe "shared class strings" do
    # @spec LIST-DETAIL-001 @spec LIST-DETAIL-004
    it "exposes a single grid class string with the shared template and gap-6 spacing" do
      expect(helper.master_detail_grid_classes).to eq("grid gap-6 lg:grid-cols-[22rem_minmax(0,1fr)]")
    end

    # @spec LIST-DETAIL-002 @spec LIST-DETAIL-004
    it "exposes a single pane-card chrome so the list and detail halves read as one card" do
      expect(helper.master_detail_pane_classes).to eq(
        "overflow-hidden rounded-xl border border-gray-200 bg-white shadow-sm"
      )
    end

    # @spec LIST-DETAIL-003 @spec LIST-DETAIL-004
    it "exposes a single selected-row class set so both screens render the same active state" do
      expect(helper.master_detail_active_row_classes).to eq("bg-indigo-50 ring-1 ring-inset ring-indigo-200")
    end

    # @spec LIST-DETAIL-002 @spec LIST-DETAIL-004
    it "exposes a single empty-state chrome so the no-selection card matches the populated card" do
      expect(helper.master_detail_empty_state_classes).to eq(
        "rounded-xl border border-dashed border-gray-300 bg-white px-6 py-12 text-center shadow-sm"
      )
    end
  end

  describe "shared/_list_detail_shell" do
    def render_shell(**locals)
      html = render(partial: "shared/list_detail_shell", locals: { list: "<p>list body</p>".html_safe, **locals })
      Nokogiri::HTML.fragment(html)
    end

    # @spec LIST-DETAIL-001 @spec LIST-DETAIL-002 @spec LIST-DETAIL-005
    it "wraps both panes in the shared grid and pane chrome" do
      document = render_shell(detail: "<p>detail body</p>".html_safe)
      grid = document.at_css("div.grid")

      expect(grid[:class]).to eq(helper.master_detail_grid_classes)
      expect(document.at_css("#list-detail-list")[:class]).to eq(helper.master_detail_pane_classes)
      expect(document.at_css("#list-detail-detail")[:class]).to eq(helper.master_detail_pane_classes)
      expect(document.at_css("#list-detail-detail").text).to include("detail body")
    end

    # @spec LIST-DETAIL-001 @spec LIST-DETAIL-005
    # Regression for #3881: passing `data:` keys straight through keeps
    # `tag.div`'s built-in `data-` + dasherize conversion as the single
    # prefix site, so a caller-supplied `data-inbox-master-detail-target`
    # reaches the DOM as `data-inbox-master-detail-target` (not
    # `data-data-inbox-master-detail-target`) and the inbox
    # master-detail Stimulus targets resolve.
    it "passes list_data and detail_data straight through to tag.div so the data- prefix is applied once" do
      document = render_shell(
        detail: "<p>detail body</p>".html_safe,
        list_dom_id: "inbox-list",
        detail_dom_id: "inbox-detail-pane",
        list_data: { "inbox-master-detail-target" => "list" },
        detail_data: { "inbox-master-detail-target" => "detailSection" }
      )

      expect(document.at_css("#inbox-list")["data-inbox-master-detail-target"]).to eq("list")
      expect(document.at_css("#inbox-detail-pane")["data-inbox-master-detail-target"]).to eq("detailSection")
      expect(document.to_html).not_to include("data-data-")
    end

    # @spec LIST-DETAIL-002 @spec LIST-DETAIL-005
    it "renders the shared empty-state card in the detail pane when detail is blank and empty_title is set" do
      document = render_shell(detail: nil, empty_title: "Nothing selected", empty_body: "Pick something.")
      empty_card = document.at_css("#list-detail-detail > div")

      expect(empty_card[:class]).to eq(helper.master_detail_empty_state_classes)
      expect(empty_card.at_css("h2").text).to eq("Nothing selected")
      expect(empty_card.at_css("p").text).to eq("Pick something.")
    end

    # @spec LIST-DETAIL-005
    it "leaves the detail pane empty when detail is blank and no empty_title is given" do
      document = render_shell

      expect(document.at_css("#list-detail-detail").text.strip).to eq("")
      expect(document.at_css("#list-detail-detail .border-dashed")).to be_nil
    end
  end
end
