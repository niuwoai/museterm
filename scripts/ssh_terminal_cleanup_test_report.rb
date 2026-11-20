#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "time"

ROOT = File.expand_path("..", __dir__)
REPORT_ROOT = File.join(ROOT, "reports", "ssh-terminal-cleanup")
DERIVED_DATA = ENV.fetch("MUSETERM_TEST_DERIVED_DATA", File.join(ROOT, ".derivedData", "ssh-terminal-cleanup"))
BUNDLE_ID = "im.some.museterm.goaltests.sshcleanup"
APP_VERSION = File.read(File.join(ROOT, "museterm", "AppVersion.swift")).match(/static let value = "([^"]+)"/).captures.first
BUILD_VERSION = File.read(File.join(ROOT, "museterm.xcodeproj", "project.pbxproj")).match(/CURRENT_PROJECT_VERSION = (\d+);/).captures.first.to_i
TEST_IDENTIFIERS = ARGV.empty? ? ["musetermTests"] : ARGV
abort "Expected musetermTests[/TestClass[/testMethod]]" unless TEST_IDENTIFIERS.all? { |identifier| identifier.match?(/\AmusetermTests(?:\/[A-Za-z_]\w*){0,2}\z/) }
REPORT_NAME = ARGV.empty? ? "unit" : "focused"

def public_report_path(path)
  prefix = "#{ROOT}/"
  path.start_with?(prefix) ? path.delete_prefix(prefix) : File.join("$DERIVED_DATA", File.basename(path))
end

FileUtils.mkdir_p(REPORT_ROOT)
FileUtils.mkdir_p(DERIVED_DATA)
run_id = Time.now.utc.strftime("%Y%m%dT%H%M%S")
result_bundle = File.join(DERIVED_DATA, "#{run_id}.xcresult")
log_path = File.join(DERIVED_DATA, "#{run_id}.log")
command = [
  "xcodebuild", "test", "-project", File.join(ROOT, "museterm.xcodeproj"),
  "-scheme", "museterm", "-destination", "platform=macOS", "-parallel-testing-enabled", "NO",
  "-derivedDataPath", DERIVED_DATA, "-resultBundlePath", result_bundle,
  *TEST_IDENTIFIERS.map { |identifier| "-only-testing:#{identifier}" }, "CODE_SIGN_IDENTITY=-", "DEVELOPMENT_TEAM=",
  "ENABLE_HARDENED_RUNTIME=NO", "GENERATE_INFOPLIST_FILE=YES", "PRODUCT_BUNDLE_IDENTIFIER=#{BUNDLE_ID}"
]
if (packages = ENV["MUSETERM_TEST_SOURCE_PACKAGES"])
  command.concat(["-clonedSourcePackagesDirPath", packages, "-disableAutomaticPackageResolution"])
end
started_at = Time.now.utc
status = nil
File.open(log_path, "w") do |log|
  Open3.popen2e(*command, chdir: ROOT) do |input, output, process|
    input.close
    output.each_line do |raw_line|
      log.write(raw_line)
      line = raw_line.dup.force_encoding(Encoding::UTF_8).scrub
      if line.match?(/error:|\*\* TEST |Executed \d+ tests?|Test Suite 'All tests'|Test Suite 'Selected tests'/)
        puts line.gsub(Dir.home, "$HOME")
        $stdout.flush
      end
    end
    status = process.value
  end
end
summary_output, summary_error, summary_status = Open3.capture3(
  "xcrun", "xcresulttool", "get", "test-results", "summary", "--path", result_bundle, "--format", "json"
)
summary = summary_status.success? ? JSON.parse(summary_output.force_encoding(Encoding::UTF_8)) : nil
summary_error = summary_error.force_encoding(Encoding::UTF_8).scrub
summary&.fetch("devicesAndConfigurations", [])&.each do |configuration|
  configuration.fetch("device", {}).delete("deviceId")
end
report = {
  schemaVersion: 1,
  generatedAt: Time.now.utc.iso8601,
  version: APP_VERSION,
  build: BUILD_VERSION,
  scope: "Native unit and integration tests; an isolated application bundle ID and derived data are used.",
  onlyTesting: TEST_IDENTIFIERS,
  durationSeconds: (Time.now.utc - started_at).round(3),
  success: status.success? && !summary.nil? && summary.fetch("failedTests", 0).zero? && summary.fetch("passedTests", 0).positive?,
  exitStatus: status.exitstatus,
  resultBundle: public_report_path(result_bundle),
  buildLog: public_report_path(log_path),
  summary: summary,
  summaryError: summary_status.success? ? nil : summary_error.gsub(Dir.home, "$HOME")
}
json_path = File.join(REPORT_ROOT, "#{REPORT_NAME}.json")
markdown_path = File.join(REPORT_ROOT, "#{REPORT_NAME}.md")
File.write(json_path, JSON.pretty_generate(report) + "\n")
markdown = [
  "# SSH 断连终端清理：原生测试", "",
  "- 版本：#{report[:version]} / Build #{report[:build]}",
  "- 结果：#{report[:success] ? 'PASS' : 'FAIL'}",
  "- 范围：原生单元与集成测试；使用独立应用标识及构建目录，不替换已安装应用。",
  "- 耗时：#{report[:durationSeconds]} 秒",
  "- Xcode 结果（本地文件）：`#{report[:resultBundle]}`", ""
]
if summary
  markdown.concat([
    "- 通过：#{summary.fetch('passedTests', 0)}",
    "- 失败：#{summary.fetch('failedTests', 0)}",
    "- 跳过：#{summary.fetch('skippedTests', 0)}", ""
  ])
  failures = summary.fetch("testFailures", [])
  unless failures.empty?
    markdown.concat(["## 失败详情", "", "```json", JSON.pretty_generate(failures), "```", ""])
  end
else
  markdown.concat(["未能读取测试结果摘要。完整构建输出保留在隔离构建目录中。", ""])
end
File.write(markdown_path, markdown.join("\n"))
puts JSON.generate(success: report[:success], jsonReport: public_report_path(json_path), markdownReport: public_report_path(markdown_path),
  passedTests: summary&.fetch("passedTests", nil), failedTests: summary&.fetch("failedTests", nil))
exit(report[:success] ? 0 : 1)
