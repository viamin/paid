class AddEnhanceIssueLoopSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :enhance_issue_needs_input_label_name, :string, default: "paid-needs-input", null: false
    add_column :projects, :enhance_issue_enhanced_label_name, :string, default: "paid-enhanced", null: false
    add_column :projects, :max_enhance_issue_reevaluation_rounds, :integer, default: 3, null: false
    add_column :issues, :enhance_issue_rounds, :integer, default: 0, null: false
  end
end
