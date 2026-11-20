#!/usr/bin/env ruby
require "json"
require "tmpdir"
require "fileutils"
require "securerandom"
require "digest"
require "open3"
require "time"
require_relative "support/runtime_probe_client"

# Build a private Debug QA copy. Never launch or quit the installed application,
# read its credentials, or stop its process-owning runtime.
source = File.expand_path(ARGV.fetch(0))
prefix = File.expand_path(ARGV.fetch(1, "reports/runtime-cold-start"))
raise "Provide a built application" unless File.executable?(File.join(source, "Contents/MacOS/MuseTerm"))
qa = Dir.mktmpdir("museterm-native-qa-", "/private/tmp")
File.chmod(0o700, qa)
tools = File.join(qa, "Tools")
Dir.mkdir(tools, 0o700)
backend = "/private/tmp/qrt-ui-#{Process.uid}-#{Digest::SHA256.hexdigest(tools)[0, 20]}"
app = File.join(qa, "MuseTermQA.app")
identifier = "im.some.museterm.goaltests.cold#{SecureRandom.hex(6)}"
credentials = {"clientID" => "museterm-qa-#{SecureRandom.hex(6)}", "token" => SecureRandom.hex(32)}
owner = SecureRandom.uuid
checks = []
pid = nil
failure = nil
version = nil

def run(*command)
  out, err, result = Open3.capture3(*command)
  raise "#{command.first} failed: #{err.byteslice(0, 500)}" unless result.success?
  out
end

def await(label, timeout: 20)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
  loop do
    result = yield
    return result if result
    raise "Timed out: #{label}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    sleep 0.05
  end
end

def read_state(tools)
  path = File.join(tools, "state.json")
  File.file?(path) ? JSON.parse(File.read(path, encoding: "UTF-8")) : {}
end

def connected_tab(tools)
  read_state(tools).fetch("tabs", []).find { |tab| tab.dig("runtime", "connected") }
end

def request(tools, credentials, owner, action, fields = {})
  id = SecureRandom.uuid
  value = {"id" => id, "action" => action, "controlID" => owner,
    "clientID" => credentials.fetch("clientID"), "authToken" => credentials.fetch("token")}.merge(fields)
  path = File.join(tools, "requests", "#{id}.json")
  pending = path + ".pending"
  File.open(pending, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(JSON.generate(value)) }
  File.rename(pending, path)
  response_path = File.join(tools, "responses", "#{id}.json")
  response = await("private UI #{action}") do
    JSON.parse(File.read(response_path, encoding: "UTF-8")) if File.file?(response_path)
  end
  raise "Private UI #{action} rejected: #{response['error']}" unless response["ok"]
  File.unlink(response_path)
  response
end

def quit_app(identifier, pid)
  run("/usr/bin/osascript", "-e", "tell application id \"#{identifier}\" to quit")
  await("private application exit") { Process.waitpid(pid, Process::WNOHANG) }
end

def stop_private_backend(root)
  return unless File.socket?(File.join(root, "runtime.sock"))
  raise "Not an owned test backend" unless root.start_with?("/private/tmp/qrt-ui-#{Process.uid}-")
  client = RuntimeProbeClient.new(root)
  state = client.request("list")
  raise "Private backend list failed" unless state["ok"]
  state.fetch("sessions").each do |session|
    closed = client.request("close", session.slice("generation", "controlEpoch").merge("sessionID" => session.fetch("id")))
    raise "Private backend close failed" unless closed["ok"]
  end
  raise "Private backend shutdown failed" unless client.request("shutdownIfEmpty")["ok"]
  client.close
  client = nil
  await("private service shutdown") do
    begin
      socket = UNIXSocket.new(File.join(root, "runtime.sock")); socket.close
      false
    rescue Errno::ECONNREFUSED, Errno::ENOENT
      true
    end
  end
rescue Errno::ECONNREFUSED, Errno::ENOENT
  # A service already stopped by this fixture needs no further cleanup.
ensure
  client&.close
end

begin
  FileUtils.cp_r(source, app)
  plist = File.join(app, "Contents/Info.plist")
  info = JSON.parse(run("/usr/bin/plutil", "-convert", "json", "-o", "-", plist))
  version = info.fetch("CFBundleShortVersionString")
  info["CFBundleIdentifier"] = identifier
  info["CFBundleName"] = "MuseTerm QA"
  info["SUEnableAutomaticChecks"] = false
  info["SUAutomaticallyUpdate"] = false
  File.write(plist, JSON.generate(info))
  run("/usr/bin/plutil", "-convert", "xml1", plist)
  run("/usr/bin/codesign", "--force", "--deep", "--sign", "-", app)
  File.open(File.join(tools, "project-tool-fixture.json"), File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(JSON.generate(credentials)) }
  environment = {"MUSETERM_AGENT_TEST_TOOL_ROOT" => tools, "MUSETERM_UI_TEST_RUNTIME" => "1",
    "MUSETERM_GUI_TOOL_FIXTURE" => "1", "HOME" => qa, "ZDOTDIR" => qa, "XDG_CONFIG_HOME" => File.join(qa, "config"),
    "LLVM_PROFILE_FILE" => File.join(qa, "coverage-%p.profraw")}
  arguments = ["-AppleLanguages", "(en)", "-terminal.showsTabList", "YES", "-notifications.enabled", "NO",
    "-SUEnableAutomaticChecks", "NO", "-ui-testing-agent-state", "-ui-testing-project-workspace", "-ui-testing-runtime"]
  launch_app = lambda do
    File.unlink(File.join(tools, "state.json")) if File.file?(File.join(tools, "state.json"))
    Process.spawn(environment, File.join(app, "Contents/MacOS/MuseTerm"), *arguments,
      out: File.join(qa, "application.log"), err: [:child, :out])
  end
  pid = launch_app.call
  original = await("initial private terminal") { connected_tab(tools) }
  original_id = original.fetch("id")
  original_identity = original.fetch("runtime").slice("pid", "generation")
  checks << "initial_gui_terminal_connected"
  quit_app(identifier, pid); pid = nil
  pid = launch_app.call
  warm = await("warm GUI recovery") { connected_tab(tools) }
  raise "Warm relaunch replaced the original process" unless warm["id"] == original_id && warm.fetch("runtime").slice("pid", "generation") == original_identity
  checks << "normal_quit_and_relaunch_preserved_original_pty"
  2.times do |iteration|
    quit_app(identifier, pid); pid = nil
    stop_private_backend(backend)
    pid = launch_app.call
    cold = await("cold GUI recovery #{iteration + 1}") { connected_tab(tools) }
    raise "Cold recovery lost layout identity" unless cold["id"] == original_id
    identity = cold.fetch("runtime").slice("pid", "generation")
    raise "Cold recovery retained dead generation" if identity["generation"] == original_identity["generation"]
    original_identity = identity
    sleep 0.5 # Let the login shell finish configuring echo before actual input.
    request(tools, credentials, owner, "takeover_tab", "tab" => original_id)
    request(tools, credentials, owner, "send_text", "tab" => original_id,
      "text" => "printf '\\n__COLD_GUI_%s_#{iteration}\\n' VERIFIED\n")
    request(tools, credentials, owner, "release_tab", "tab" => original_id)
    await("actual command output after cold start") do
      connected_tab(tools)&.fetch("screen", "")&.lines&.map(&:strip)&.include?("__COLD_GUI_VERIFIED_#{iteration}")
    end
    checks << "cold_start_#{iteration + 1}_new_generation_and_real_ui_input_output"
  end
  run("/usr/bin/osascript", "-e", "tell application id \"#{identifier}\" to activate")
  sleep 1
  FileUtils.mkdir_p(File.dirname(prefix))
  window_script = 'import CoreGraphics; import Foundation; let pid = Int(CommandLine.arguments[1])!; let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []; if let w = windows.first(where: { ($0[kCGWindowOwnerPID as String] as? Int) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }), let id = w[kCGWindowNumber as String] as? Int { print(id) }'
  window_id = run("/usr/bin/swift", "-e", window_script, pid.to_s).strip
  raise "QA application has no visible window" if window_id.empty?
  run("/usr/sbin/screencapture", "-x", "-o", "-l", window_id, "#{prefix}.png")
  checks << "native_application_window_captured"
rescue => error
  failure = "#{error.class}: #{error.message}"
ensure
  begin
    quit_app(identifier, pid) if pid
    stop_private_backend(backend)
    FileUtils.remove_entry_secure(backend) if File.directory?(backend)
    FileUtils.remove_entry_secure(qa)
    checks << "private_app_and_backend_cleaned_up"
  rescue => error
    failure ||= "Cleanup failed: #{error.class}: #{error.message}"
  end
  FileUtils.mkdir_p(File.dirname(prefix))
  report = {"version" => version, "passed" => failure.nil?, "visualInspection" => "required",
    "checks" => checks, "failure" => failure, "timestamp" => Time.now.iso8601}
  File.write("#{prefix}.json", JSON.pretty_generate(report) + "\n")
  File.write("#{prefix}.md", "# MuseTerm 冷启动原生应用验证\n\n版本：#{version}\n\n自动检查：#{failure ? '失败' : '通过'}\n\n截图仍须人工核对，不以内部屏幕文本代替可见画面。\n\n" + checks.map { |check| "- #{check}\n" }.join + (failure ? "\n失败：#{failure}\n" : ""))
  puts JSON.generate(report)
end
exit(failure ? 1 : 0)
