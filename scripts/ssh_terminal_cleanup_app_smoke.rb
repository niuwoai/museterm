#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "timeout"
require "tmpdir"
require "time"
require "securerandom"
require "base64"

repository = File.expand_path("..", __dir__)
require File.join(repository, "scripts/support/runtime_probe_client")
app = File.join(repository, ".derivedData/ssh-terminal-cleanup/Build/Products/Debug/MuseTerm.app")
identifier, error, status = Open3.capture3("/usr/libexec/PlistBuddy", "-c", "Print CFBundleIdentifier", File.join(app, "Contents/Info.plist"))
raise "Refusing to drive a non-QA application: #{error}" unless status.success? && identifier.strip == "im.some.museterm.goaltests.sshcleanup"
qa = Dir.mktmpdir("museterm-native-qa-", "/private/tmp")
tools = File.join(qa, "Tools")
FileUtils.mkdir_p(tools, mode: 0700)
backend = "/private/tmp/qrt-ui-#{Process.uid}-#{Digest::SHA256.hexdigest(tools)[0, 20]}"
report_directory = ENV.fetch("MUSETERM_QA_REPORT_DIRECTORY", File.join(repository, "reports/ssh-terminal-cleanup/native-runtime-gui"))
FileUtils.mkdir_p(report_directory)
log = File.open(File.join(repository, ".derivedData/native-runtime-smoke.log"), "w")
pid = nil
client = nil
checks = []
report = {generatedAt: Time.now.utc.iso8601, scope: "Actual isolated macOS application; AppleScript tab operations and screen reads, Runtime input under an owned AI control lease", success: false}

def wait_until(timeout: 20)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
  loop do
    value = yield
    return value if value
    raise "Condition timed out after #{timeout} seconds" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    sleep 0.1
  end
end

def apple_script(app, body)
  output, error, status = Open3.capture3("osascript", "-e", "tell application #{app.dump}\n#{body}\nend tell")
  raise "AppleScript failed: #{error}" unless status.success?
  output.strip
end

def checked(response)
  raise "Private QA Runtime rejected the request: #{response['error']}" unless response["ok"]
  response
end

def target(info)
  {"sessionID" => info.fetch("id"), "generation" => info.fetch("generation"), "controlEpoch" => info.fetch("controlEpoch")}
end

begin
  pid = Process.spawn({"MUSETERM_AGENT_TEST_TOOL_ROOT" => tools, "HOME" => qa, "ZDOTDIR" => qa},
    File.join(app, "Contents/MacOS/MuseTerm"), "-AppleLanguages", "(en)",
    "-notifications.enabled", "NO", "-SUEnableAutomaticChecks", "NO",
    "-terminal.skipRunningTabCloseConfirmation", "YES", "-ui-testing-agent-state",
    "-ui-testing-project-workspace", "-ui-testing-runtime", out: log, err: log)
  state = wait_until do
    path = File.join(tools, "state.json")
    next false unless File.file?(path)
    value = JSON.parse(File.read(path))
    value if value.fetch("tabs", []).length >= 1
  end
  report[:applicationVersion] = state.fetch("version")
  checks << "实际 QA 应用启动并显示终端标签"
  tab_id = apple_script(app, "set t to create tab in directory #{qa.dump}\nget id of t")
  raise "Unexpected terminal identity" unless tab_id.match?(/\A[0-9A-Fa-f-]{36}\z/)
  checks << "通过 AppleScript 创建独立测试标签"
  wait_until do
    state = JSON.parse(File.read(File.join(tools, "state.json")))
    state.fetch("tabs").any? { |tab| tab.fetch("id").casecmp?(tab_id) && tab.fetch("screen", "").include?("%") }
  end
  client = RuntimeProbeClient.new(backend)
  info = checked(client.request("list")).fetch("sessions").find { |value| value.fetch("id").casecmp?(tab_id) }
  raise "QA terminal missing or not running" unless info && info["running"]
  owner = "native-qa-control-" + SecureRandom.uuid
  info = checked(client.request("acquireControl", target(info).merge("owner" => owner))).fetch("session")
  raise "AI lease was not granted" unless info["controlOwner"] == owner
  checks << "取得仅属于本次 QA 的 AI 控制租约"
  inspection = checked(client.request("inspectInput", target(info)))
  info = inspection.fetch("session")
  # zsh's line editor normally disables kernel echo at its own prompt. Pin the
  # observed echo mode and require the foreground group to be this fresh QA shell.
  raise "Unexpected foreground process in QA terminal" unless inspection.fetch("foregroundPID") == info.fetch("pid")
  input = target(info).merge("source" => "ai", "owner" => owner,
    "inputSequence" => info.fetch("nextInputSequence"),
    "expectedEchoEnabled" => inspection.fetch("echoEnabled"),
    "expectedForegroundPID" => inspection.fetch("foregroundPID"),
    "data" => Base64.strict_encode64("printf '__SSH_CLEANUP_QA_%s\\n' READY\r"))
  info = checked(client.request("input", input)).fetch("session")
  checks << "按当前 generation、控制 epoch 与前台进程校验发送终端命令"
  screen = wait_until do
    value = apple_script(app, "get contents of tab id #{tab_id.dump}")
    value if value.include?("__SSH_CLEANUP_QA_READY")
  end
  report[:terminalInputVerified] = true
  report[:screenContainsExecutedMarker] = screen.include?("__SSH_CLEANUP_QA_READY")
  checks << "从实际 App 屏幕读到命令执行结果，排除仅命令回显"
  info = checked(client.request("list")).fetch("sessions").find { |value| value.fetch("id").casecmp?(tab_id) }
  checked(client.request("releaseControl", target(info).merge("owner" => owner)))
  checks << "通过 Runtime 正常释放本次控制租约"

  apple_script(app, "activate")
  window_source = 'import CoreGraphics; import Foundation; let pid = Int(CommandLine.arguments[1])!; let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []; let windows = list.filter { window in guard (window[kCGWindowOwnerPID as String] as? Int) == pid, (window[kCGWindowLayer as String] as? Int) == 0, let bounds = window[kCGWindowBounds as String] as? [String: Double] else { return false }; return (bounds["Width"] ?? 0) > 100 && (bounds["Height"] ?? 0) > 100 }; if let id = windows.first?[kCGWindowNumber as String] as? Int { print(id) }'
  window, window_error, window_status = Open3.capture3("xcrun", "swift", "-e", window_source, pid.to_s)
  if window_status.success? && window.strip.match?(/\A\d+\z/)
    screenshot = File.join(report_directory, "native-terminal.png")
    _, capture_error, capture_status = Open3.capture3("/usr/sbin/screencapture", "-x", "-l", window.strip, screenshot)
    report[:localScreenshot] = File.basename(screenshot) if capture_status.success?
    report[:screenshotError] = capture_error.strip unless capture_status.success?
  else
    report[:screenshotError] = window_error.strip.empty? ? "No visible window belonging to the QA app" : window_error.strip
  end
  apple_script(app, "close tab #{tab_id.dump} skipping confirmation true")
  wait_until do
    state = JSON.parse(File.read(File.join(tools, "state.json")))
    state.fetch("tabs").none? { |tab| tab.fetch("id").casecmp?(tab_id) }
  end
  checks << "关闭本次创建的测试标签并确认已从实际 App 状态移除"
  report[:success] = true
rescue StandardError => error
  report[:success] = false
  report[:error] = "#{error.class}: #{error.message}"
ensure
  client&.close
  if pid
    begin
      Process.kill("TERM", pid)
      Timeout.timeout(8) { Process.wait(pid) }
    rescue Errno::ESRCH, Errno::ECHILD
      # The owned QA application has already exited.
    rescue Timeout::Error
      Process.kill("KILL", pid)
      Process.wait(pid)
    end
  end
  if File.socket?(File.join(backend, "runtime.sock"))
    begin
      cleanup = RuntimeProbeClient.new(backend)
      checked(cleanup.request("list")).fetch("sessions").each do |info|
        checked(cleanup.request("close", target(info)))
      end
      checked(cleanup.request("shutdownIfEmpty"))
      cleanup.close
      report[:privateBackendCleanup] = true
    rescue StandardError => error
      report[:privateBackendCleanup] = false
      report[:cleanupError] = "#{error.class}: #{error.message}"
      report[:success] = false
    end
  end
  log.close
  report[:checks] = checks
  report.transform_values! { |value| value.is_a?(String) ? value.gsub(repository, ".").gsub(Dir.home, "$HOME") : value }
  report[:screenshotPublication] = "Local only; excluded from Git because terminal prompts can identify the local user and host."
  File.write(File.join(report_directory, "app-smoke.json"), JSON.pretty_generate(report) + "\n")
  text = ["# 原生应用隔离交互验证", "", "- 版本：#{report[:applicationVersion] || '未读取'}", "- 结果：#{report[:success] ? 'PASS' : 'FAIL'}", "- 范围：实际 QA App；AppleScript 创建标签与读取屏幕，Runtime 租约内输入。", "- 侧栏视图、终端异常退出及其他回归另由原生测试覆盖；本次范围仅为实际 App 的标签和终端交互。", "- 截图仅保留本地并由 Git 忽略，上传前必须脱敏终端中的用户及主机标识。", "- 复用建议：可通过 /run-skill-generator 固化隔离启动和租约驱动。", ""]
  text << "- 窗口截图：#{report[:localScreenshot] ? '已抓取，仅本地保留' : report[:screenshotError] || '未生成'}"
  text.concat(checks.map { |check| "- #{check}" })
  text.concat(["", report[:error].to_s, report[:cleanupError].to_s, ""])
  File.write(File.join(report_directory, "app-smoke.md"), text.join("\n").rstrip + "\n")
end
puts JSON.generate(report)
exit(report[:success] ? 0 : 1)
