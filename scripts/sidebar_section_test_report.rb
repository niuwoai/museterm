#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "time"

ROOT = File.expand_path("..", __dir__)
REPORT_ROOT = File.join(ROOT, "reports", "sidebar-section-expansion")
DERIVED_DATA = File.join(ROOT, ".derivedData", "ssh-terminal-cleanup")
IDENTIFIERS = ARGV.empty? ? ["musetermTests"] : ARGV
abort "Expected musetermTests[/TestClass[/testMethod]]" unless IDENTIFIERS.all? { |value| value.match?(/\AmusetermTests(?:\/[A-Za-z_]\w*){0,2}\z/) }
NAME = ARGV.empty? ? "unit" : "focused"
version = File.read(File.join(ROOT, "museterm/AppVersion.swift")).match(/static let value = "([^"]+)"/).captures.first
build = File.read(File.join(ROOT, "museterm.xcodeproj/project.pbxproj")).match(/CURRENT_PROJECT_VERSION = (\d+);/).captures.first.to_i
FileUtils.mkdir_p(REPORT_ROOT)
FileUtils.mkdir_p(DERIVED_DATA)
run_id = Time.now.utc.strftime("%Y%m%dT%H%M%S")
result_bundle = File.join(DERIVED_DATA, "#{run_id}.xcresult")
log_path = File.join(DERIVED_DATA, "#{run_id}.log")
command = [
  "xcodebuild", "test", "-project", File.join(ROOT, "museterm.xcodeproj"),
  "-scheme", "museterm", "-destination", "platform=macOS", "-parallel-testing-enabled", "NO",
  "-derivedDataPath", DERIVED_DATA, "-resultBundlePath", result_bundle,
  *IDENTIFIERS.map { |identifier| "-only-testing:#{identifier}" },
  "CODE_SIGN_IDENTITY=-", "DEVELOPMENT_TEAM=", "ENABLE_HARDENED_RUNTIME=NO",
  "GENERATE_INFOPLIST_FILE=YES", "PRODUCT_BUNDLE_IDENTIFIER=im.some.museterm.goaltests.sshcleanup"
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
output, error, summary_status = Open3.capture3(
  "xcrun", "xcresulttool", "get", "test-results", "summary", "--path", result_bundle, "--format", "json"
)
summary = summary_status.success? ? JSON.parse(output.force_encoding(Encoding::UTF_8)) : nil
success = status.success? && !summary.nil? && summary.fetch("failedTests", 0).zero? && summary.fetch("passedTests", 0).positive?
relative = ->(path) { path.delete_prefix("#{ROOT}/") }
report = {
  schemaVersion: 1, generatedAt: Time.now.utc.iso8601, version: version, build: build,
  scope: "Native unit and integration tests, including real SwiftUI sidebar hosts; isolated QA application and build directory.",
  onlyTesting: IDENTIFIERS, success: success, exitStatus: status.exitstatus,
  durationSeconds: (Time.now.utc - started_at).round(3),
  passedTests: summary&.fetch("passedTests", 0), failedTests: summary&.fetch("failedTests", 0),
  skippedTests: summary&.fetch("skippedTests", 0),
  failures: summary&.fetch("testFailures", []) || [],
  resultBundle: relative.call(result_bundle), buildLog: relative.call(log_path),
  summaryError: summary_status.success? ? nil : error.force_encoding(Encoding::UTF_8).scrub.gsub(Dir.home, "$HOME")
}
File.write(File.join(REPORT_ROOT, "#{NAME}.json"), JSON.pretty_generate(report) + "\n")
markdown = [
  "# 侧栏分区展开状态：原生测试", "",
  "- 版本：#{version} / Build #{build}", "- 结果：#{success ? 'PASS' : 'FAIL'}",
  "- 范围：#{IDENTIFIERS.join(', ')}；独立 QA App，不替换已安装应用。",
  "- 通过：#{report[:passedTests]}", "- 失败：#{report[:failedTests]}", "- 跳过：#{report[:skippedTests]}",
  "- 耗时：#{report[:durationSeconds]} 秒", "- Xcode 结果（仅本地）：`#{report[:resultBundle]}`"
]
unless report[:failures].empty?
  markdown.concat(["", "## 失败详情", "", "```json", JSON.pretty_generate(report[:failures]), "```"])
end
markdown.concat(["", report[:summaryError]]) if report[:summaryError]
File.write(File.join(REPORT_ROOT, "#{NAME}.md"), markdown.join("\n") + "\n")
puts JSON.generate(success: success, passedTests: report[:passedTests], failedTests: report[:failedTests],
  jsonReport: relative.call(File.join(REPORT_ROOT, "#{NAME}.json")))
exit(success ? 0 : 1)
