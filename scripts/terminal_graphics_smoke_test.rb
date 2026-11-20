#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "time"

ROOT = File.expand_path("..", __dir__)
REPORT_DIR = File.join(ROOT, "reports")
JSON_REPORT = File.join(REPORT_DIR, "terminal_graphics_report.json")
MARKDOWN_REPORT = File.join(REPORT_DIR, "terminal_graphics_report.md")
PROJECT = "museterm.xcodeproj"
SCHEME = "museterm"
TEST_TARGET = "musetermTests/TerminalGraphicsPolicyTests"

started_at = Time.now
command = [
  "xcodebuild",
  "test",
  "-project", PROJECT,
  "-scheme", SCHEME,
  "-destination", "platform=macOS",
  "-only-testing:#{TEST_TARGET}"
]

stdout, stderr, status = Open3.capture3(*command, chdir: ROOT)
finished_at = Time.now
combined_output = [stdout, stderr].reject(&:empty?).join("\n")
sanitized_output = combined_output
  .gsub(Dir.home, "$HOME")
  .gsub(/Signing Identity:\s+"[^"]+"/, "Signing Identity: <redacted>")
  .gsub(/--sign\s+[A-F0-9]{20,}/, "--sign <redacted>")
summary_lines = sanitized_output.lines.select do |line|
  line.match?(/Test (suite|case) 'TerminalGraphicsPolicyTests/) ||
    line.include?("** TEST SUCCEEDED **") ||
    line.include?("** TEST FAILED **") ||
    line.include?("xcodebuild: error:")
end
tail = summary_lines.last(120).join

test_names = %w[
  testDefaultGraphicsPolicyAdvertisesSixelAndCapsKittyCache
  testGraphicsCacheClampsToSupportedRange
  testGraphicsEnvironmentAdvertisesAppAndProtocols
  testImageCachePreferencePersistsAndClamps
  testITerm2InlineImageSequenceDeliversEncodedImage
  testKittyInlinePNGSequenceDeliversEncodedImage
  testSixelSequenceDeliversRGBABitmap
]

checks = test_names.map do |test_name|
  passed = status.success? && combined_output.include?(test_name)
  { name: test_name, passed: passed }
end

report = {
  schema_version: 1,
  generated_at: finished_at.iso8601,
  duration_seconds: (finished_at - started_at).round(3),
  command: command,
  success: status.success?,
  exit_status: status.exitstatus,
  protocols: %w[kitty iterm2 sixel],
  checks: checks,
  output_tail: tail
}

FileUtils.mkdir_p(REPORT_DIR)
File.write(JSON_REPORT, JSON.pretty_generate(report) + "\n")

markdown = [
  "# Terminal Graphics Smoke Test",
  "",
  "- Generated: #{report[:generated_at]}",
  "- Result: #{report[:success] ? 'PASS' : 'FAIL'}",
  "- Duration: #{report[:duration_seconds]}s",
  "- Protocols: Kitty, iTerm2, Sixel",
  "",
  "## Checks",
  ""
]
checks.each do |check|
  markdown << "- [#{check[:passed] ? 'x' : ' '}] `#{check[:name]}`"
end
markdown.concat([
  "",
  "## Build Output Tail",
  "",
  "```text",
  tail.rstrip,
  "```",
  ""
])
File.write(MARKDOWN_REPORT, markdown.join("\n"))

puts JSON.generate(
  success: report[:success],
  json_report: JSON_REPORT,
  markdown_report: MARKDOWN_REPORT
)
exit(status.exitstatus || 1)
