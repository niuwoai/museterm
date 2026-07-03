#!/usr/bin/env ruby
# frozen_string_literal: true

# MuseTerm AppleScript 冒烟测试。
#
# 前置条件：
#   1. museterm.app 正在运行（任意标签数均可）；
#   2. 运行本脚本的终端已获得 macOS「自动化」授权（首次运行会弹窗）；
#   3. 若要通过 execute 用例，目标标签需启用 shell integration。
#
# 用法：
#   ruby scripts/applescript_smoke_test.rb [--app museterm] [--out reports]
#
# 输出：reports/applescript_smoke_report.json 与 .md 双格式报告。

require "json"
require "open3"
require "fileutils"
require "time"

app_name = "museterm"
out_dir = "reports"
ARGV.each_with_index do |arg, i|
  app_name = ARGV[i + 1] if arg == "--app" && ARGV[i + 1]
  out_dir = ARGV[i + 1] if arg == "--out" && ARGV[i + 1]
end

def osascript(script)
  stdout, stderr, status = Open3.capture3("osascript", "-e", script)
  { ok: status.success?, stdout: stdout.strip, stderr: stderr.strip }
end

results = []

def run_case(results, name, description, script, expect: nil)
  started = Time.now
  outcome = osascript(script)
  passed = outcome[:ok] && (expect.nil? || expect.call(outcome[:stdout]))
  results << {
    name: name,
    description: description,
    script: script,
    passed: passed,
    stdout: outcome[:stdout],
    stderr: outcome[:stderr],
    duration_ms: ((Time.now - started) * 1000).round
  }
  status = passed ? "PASS" : "FAIL"
  warn "[#{status}] #{name}"
  passed
end

tell = ->(body) { "tell application \"#{app_name}\"\n#{body}\nend tell" }

running = osascript("application \"#{app_name}\" is running")
unless running[:ok] && running[:stdout] == "true"
  warn "museterm 未运行，请先启动 App 再执行冒烟测试。"
  exit 2
end

run_case(results, "count_tabs", "统计标签数",
         tell.call("count tabs"),
         expect: ->(out) { out.to_i >= 1 })

run_case(results, "selected_tab_title", "读取选中标签标题",
         tell.call("get title of selected tab"))

run_case(results, "input_allowed", "读取写入开关状态",
         tell.call("get scripted input allowed"),
         expect: ->(out) { %w[true false].include?(out) })

run_case(results, "create_tab", "新建标签",
         tell.call("set t to create tab\nget id of t"),
         expect: ->(out) { out.length >= 32 })

run_case(results, "write_text", "写入命令（echo）",
         tell.call("write text \"echo museterm-applescript-smoke\" to selected tab"))

sleep 1.0

run_case(results, "read_contents", "读取屏幕内容并校验回显",
         tell.call("get contents of selected tab"),
         expect: ->(out) { out.include?("museterm-applescript-smoke") })

run_case(results, "send_key", "发送 ctrl-c",
         tell.call("send key \"ctrl-c\" to selected tab"))

run_case(results, "execute_sync", "同步执行 true 并取退出码（需 shell integration）",
         tell.call("set r to execute \"true\" in selected tab timeout 30\nget exit code of r"),
         expect: ->(out) { out == "0" })

run_case(results, "command_records", "读取命令记录数量",
         tell.call("count command records of selected tab"),
         expect: ->(out) { out.to_i >= 0 })

run_case(results, "close_tab", "关闭最后一个标签",
         tell.call("close tab (count tabs)"))

passed = results.count { |r| r[:passed] }
report = {
  app: app_name,
  generated_at: Time.now.iso8601,
  total: results.length,
  passed: passed,
  failed: results.length - passed,
  cases: results
}

FileUtils.mkdir_p(out_dir)
json_path = File.join(out_dir, "applescript_smoke_report.json")
md_path = File.join(out_dir, "applescript_smoke_report.md")

File.write(json_path, JSON.pretty_generate(report))

md = +"# MuseTerm AppleScript 冒烟测试报告\n\n"
md << "- 生成时间：#{report[:generated_at]}\n"
md << "- 结果：#{passed}/#{results.length} 通过\n\n"
md << "| 用例 | 说明 | 结果 | 耗时 (ms) | 输出/错误 |\n|---|---|---|---|---|\n"
results.each do |r|
  detail = r[:passed] ? r[:stdout] : r[:stderr]
  detail = detail.to_s.gsub("|", "\\|").gsub("\n", " ")[0, 120]
  md << "| #{r[:name]} | #{r[:description]} | #{r[:passed] ? '✅' : '❌'} | #{r[:duration_ms]} | #{detail} |\n"
end
File.write(md_path, md)

warn "报告已写入 #{json_path} 与 #{md_path}"
exit(report[:failed].zero? ? 0 : 1)
