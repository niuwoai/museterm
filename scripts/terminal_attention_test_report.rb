#!/usr/bin/env ruby
require "json"
require "open3"
require "fileutils"
require "time"

abort "Usage: ruby scripts/terminal_attention_test_report.rb OUTPUT_PREFIX RESULT_BUNDLE..." if ARGV.length < 2
prefix = File.expand_path(ARGV.shift)
root = File.expand_path("..", __dir__)
version = File.read(File.join(root, "museterm/AppVersion.swift"))[/static let value = "([^"]+)"/, 1]
build = File.read(File.join(root, "museterm.xcodeproj/project.pbxproj"))[/CURRENT_PROJECT_VERSION = (\d+);/, 1].to_i

def read_result(kind, path)
  output, error, status = Open3.capture3("xcrun", "xcresulttool", "get", "test-results", kind,
    "--path", path, "--format", "json")
  abort "Could not read #{File.basename(path)}: #{error}" unless status.success?
  JSON.parse(output)
end

def collect_cases(nodes, target = nil, cases = {})
  nodes.each do |node|
    current = node.fetch("nodeType", "").end_with?("test bundle") ? node["name"] : target
    if node["nodeType"] == "Test Case"
      cases[[current, node["nodeIdentifier"] || node["name"]].join("/")] = node["result"]
    end
    collect_cases(node.fetch("children", []), current, cases)
  end
  cases
end

cases = {}
results = ARGV.map do |bundle|
  path = File.expand_path(bundle)
  summary = read_result("summary", path)
  cases.merge!(collect_cases(read_result("tests", path).fetch("testNodes")))
  {"bundle" => path, "result" => summary.fetch("result"), "passed" => summary.fetch("passedTests"),
   "failed" => summary.fetch("failedTests"), "skipped" => summary.fetch("skippedTests"),
   "failures" => summary.fetch("testFailures", []).map { |failure| failure.slice("testIdentifierString", "failureText") }}
end
counts = {"total" => cases.length, "passed" => cases.values.count("Passed"),
  "failed" => cases.values.count("Failed"), "skipped" => cases.values.count("Skipped")}
passed = counts["total"].positive? && counts["passed"] == counts["total"]
boundaries = [
  "普通终端响铃、命令失败、长命令完成、进程退出沿用分类开关和阈值，系统通知总开关不控制事项存在。",
  "红点来自待处理中的未读事项，仍受通知和徽标显示设置控制；已查看的 Agent 问题仍计入待处理。",
  "命令按 UUID、退出按进程代次去重，去重键最多保留 1024 条；响铃合并到未解决事项并递增版本。",
  "不同命令、Agent 业务结果和进程退出不凭文本或相近时间误合并；旧通知版本不能清除后续事项。",
  "Agent 交互组件与协议未实现；未提交、未发布、未替换已安装应用。"
]
report = {"version" => version, "build" => build, "generatedAt" => Time.now.iso8601,
  "scope" => "普通终端提醒统一存储与去重", "results" => results, "latestTestCases" => counts,
  "allPassed" => passed, "boundaries" => boundaries}
FileUtils.mkdir_p(File.dirname(prefix))
File.write("#{prefix}.json", JSON.pretty_generate(report) + "\n")
lines = ["# 普通终端提醒统一与去重验证", "", "版本：`#{version}`，Build `#{build}`。", "",
  "| 结果包 | 通过 | 失败 | 跳过 |", "|---|---:|---:|---:|"]
results.each { |r| lines << "| #{File.basename(r['bundle'])} | #{r['passed']} | #{r['failed']} | #{r['skipped']} |" }
lines += ["", "同一用例以最后一次结果为准：#{counts['passed']}/#{counts['total']} 通过，#{counts['failed']} 失败，#{counts['skipped']} 跳过。", ""]
boundaries.each { |item| lines << "- #{item}" }
results.each do |result|
  result["failures"].each { |failure| lines += ["", "早期失败：#{failure.values.compact.join(' — ')}"] }
end
File.write("#{prefix}.md", lines.join("\n") + "\n")
puts JSON.generate({"report" => "#{prefix}.json", "latestTestCases" => counts, "allPassed" => passed})
exit(passed ? 0 : 1)
