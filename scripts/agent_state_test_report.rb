#!/usr/bin/env ruby
# Summarize actual xcresult evidence without terminal text, host identifiers or credentials.
require "json"
require "open3"
require "fileutils"
require "time"

abort "Usage: ruby scripts/agent_state_test_report.rb OUTPUT_PREFIX RESULT_BUNDLE..." if ARGV.length < 2
prefix = File.expand_path(ARGV.shift)
project = File.expand_path("..", __dir__)
version = File.read(File.join(project, "museterm/AppVersion.swift"))[/static let value = "([^"]+)"/, 1]
build = File.read(File.join(project, "museterm.xcodeproj/project.pbxproj"))[/CURRENT_PROJECT_VERSION = (\d+);/, 1].to_i
abort "Missing project version." unless version && build.positive?
latest_cases = {}
def collect_cases(nodes, target = nil, cases = {})
  nodes.each do |node|
    current_target = node.fetch("nodeType", "").end_with?("test bundle") ? node["name"] : target
    if node["nodeType"] == "Test Case"
      cases[[current_target, node["nodeIdentifier"] || node["name"]].join("/")] = node["result"]
    end
    collect_cases(node.fetch("children", []), current_target, cases)
  end
  cases
end

results = ARGV.map do |bundle|
  path = File.expand_path(bundle)
  output, error, status = Open3.capture3("xcrun", "xcresulttool", "get", "test-results", "summary",
    "--path", path, "--format", "json")
  abort "Could not read test bundle #{File.basename(path)}: #{error}" unless status.success?
  summary = JSON.parse(output)
  tree_output, tree_error, tree_status = Open3.capture3("xcrun", "xcresulttool", "get", "test-results", "tests",
    "--path", path, "--format", "json")
  abort "Could not read test cases: #{tree_error}" unless tree_status.success?
  latest_cases.merge!(collect_cases(JSON.parse(tree_output).fetch("testNodes")))
  {
    "bundle" => path, "result" => summary.fetch("result"),
    "total" => summary.fetch("totalTestCount"), "passed" => summary.fetch("passedTests"),
    "failed" => summary.fetch("failedTests"), "skipped" => summary.fetch("skippedTests"),
    "failures" => summary.fetch("testFailures", []).map { |failure| failure.slice("testIdentifierString", "failureText") }
  }
end
latest = {"total" => latest_cases.length, "passed" => latest_cases.values.count("Passed"),
  "failed" => latest_cases.values.count("Failed"), "skipped" => latest_cases.values.count("Skipped")}
all_passed = latest.fetch("total").positive? && latest.fetch("passed") == latest.fetch("total")
report = {
  "version" => version, "build" => build, "generatedAt" => Time.now.iso8601,
  "scope" => ["阶段 2：待处理聚合、通知和版本绑定定位", "阶段 3：App 异步等待及 MCP 并发/取消", "阶段 4：识别回归、关闭开关和资源上限"],
  "delivery" => {"committed" => false, "released" => false, "installedAppReplaced" => false},
  "results" => results,
  "latestTestCases" => latest,
  "limits" => ["界面测试使用显式状态夹具；未运行真实 Claude/Codex 付费任务。",
    "未自动安装原生生命周期钩子；包装进程和 SSH 远端需显式结构化接入。",
    "系统通知定位校验有自动化测试；未向用户申请新的系统通知权限或发送测试通知。",
    "跨应用退出保活、原生 Agent 钩子安装和完整终端正文增量流不在本次范围。"],
  "stressCase" => {"independentWaiters" => 64, "outputRevisions" => 2000, "retainedEvents" => 1024},
  "earlierRun" => "专项测试发现 Ruby 等待清理标记作用域问题，已修复取消和 EOF 清理；界面测试按实际按钮合并可访问性文本验证已读状态。文件桥验收移至使用独立目录的原生测试宿主，避免 UI runner 与 App 容器目录隔离。布局复验曾出现截图超时和控件未找到，该轮截图可见系统钥匙串解锁弹窗；未操作弹窗。用户处理弹窗后，徽标和待处理列表通过，窗口计数等待仍超时，但失败截图确认两个窗口已显示；测试改用 XCTest 直接等待第二个窗口，保留事项点击和悬浮定位断言。失败记录保留在对应临时 xcresult 中。"
}
FileUtils.mkdir_p(File.dirname(prefix))
File.write("#{prefix}.json", JSON.pretty_generate(report) + "\n")
lines = ["# Agent 待处理、事件等待与可靠性验证", "", "版本：`#{version}`，Build `#{build}`。仅本地开发，未提交、未发布、未替换已安装应用。", "",
  "| 测试结果包 | 结果 | 通过 | 失败 | 跳过 |", "|---|---|---:|---:|---:|"]
results.each do |result|
  lines << "| #{File.basename(result.fetch("bundle"))} | #{result.fetch("result")} | #{result.fetch("passed")} | #{result.fetch("failed")} | #{result.fetch("skipped")} |"
end
lines += ["", "结果包按时间排列；同一测试以最后一次结果为准，不叠加重复用例。", "",
  "最新去重结果：#{latest.fetch("passed")}/#{latest.fetch("total")} 通过，#{latest.fetch("failed")} 失败，#{latest.fetch("skipped")} 跳过。", "", "## 边界", ""]
report.fetch("limits").each { |limit| lines << "- #{limit}" }
lines += ["", "## 首轮失败记录", "", report.fetch("earlierRun"), ""]
File.write("#{prefix}.md", lines.join("\n"))
puts JSON.generate({"report" => "#{prefix}.json", "latestTestCases" => latest, "allPassed" => all_passed})
exit(all_passed ? 0 : 1)
