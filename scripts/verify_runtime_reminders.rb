#!/usr/bin/env ruby
require "json"
require "tmpdir"
require "fileutils"
require "digest"
require "time"
require_relative "support/runtime_probe_client"
require_relative "support/runtime_wait_file_client"

def await_reminder
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
  loop do
    result = yield
    return result if result
    raise "Reminder verification timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    sleep 0.01
  end
end

binary, prefix = ARGV.take(2).map { |path| File.expand_path(path) }
root = Dir.mktmpdir("qrt-rem-", "/private/tmp")
File.chmod(0o700, root)
server = nil
client = nil
checks = []
failure = nil
begin
  server = Process.spawn(binary, "--root", root, in: File::NULL, out: File::NULL, err: File::NULL)
  await_reminder { File.file?(File.join(root, "ui-capability")) }
  client = RuntimeProbeClient.new(root)
  call = lambda do |action, fields = {}, **options|
    response = client.request(action, fields, **options)
    raise "Request rejected: #{response['error']}" unless response["ok"]
    response
  end
  metadata = call.call("list")
  raise "Reminder capability missing" unless metadata.fetch("features").include?("terminal_attention_v1")
  policy = {"bells" => true, "commandFailures" => true, "longCommandCompletion" => true, "processExits" => true,
    "longCommandSeconds" => 0, "failureMinimumSeconds" => 5}
  launch = {"executable" => "/bin/sh", "arguments" => ["-c", 'stty sane -echo; printf "__REM_READY\n"; while IFS= read -r line; do eval "$line"; done'],
    "directory" => root, "environment" => {"PATH" => "/usr/bin:/bin"}, "columns" => 80, "rows" => 24, "reminderPolicy" => policy}
  session = call.call("create", {"launch" => launch}).fetch("session")
  target = {"sessionID" => session.fetch("id"), "generation" => session.fetch("generation"), "controlEpoch" => session.fetch("controlEpoch")}
  read = lambda { call.call("read", target).fetch("data", "").unpack1("m0") }
  await_reminder { read.call.include?("__REM_READY") }
  marker = 0
  line = lambda do |command|
    marker += 1
    expected = "__REM_DONE_#{marker}"
    info = call.call("list").fetch("sessions").first
    fields = target.merge("source" => "human", "inputSequence" => info.fetch("nextInputSequence"),
      "data" => [command + "; printf '#{expected}\\n'\n"].pack("m0"))
    call.call("input", fields)
    await_reminder { read.call.include?(expected) }
    fields
  end
  items = lambda { call.call("listAttention", target).fetch("attention") }
  line.call(%q{printf '\033]0;title\007\033]777;MuseTerm;shell=sh\007\033Ppayload\007\033\134'})
  raise "Control terminators created bells" unless items.call.empty?
  checks << "osc_shell_and_dcs_terminators_are_not_bells"
  original_input = line.call(%q{printf '\007\007\007'})
  first = items.call.fetch(0)
  raise "Bell batch did not coalesce" unless items.call.length == 1 && first.dig("terminal", "occurrences") == 3
  call.call("acknowledgeAttention", {"attentionID" => first.fetch("id"), "attentionVersion" => first.fetch("version")})
  raise "Read ordinary reminder remained active" unless items.call.empty?
  line.call(%q{printf '\007'})
  raise "New post-read bell lost" if items.call.fetch(0)["id"] == first["id"]
  checks << "single_inbox_bell_batch_read_resolution_and_new_bell_identity"
  # Re-delivery of an accepted input request returns the original ACK, never rings again.
  info = call.call("list").fetch("sessions").first
  request_id = SecureRandom.uuid
  input = target.merge("source" => "human", "inputSequence" => info.fetch("nextInputSequence"), "data" => [%q{printf '\007'} + "\n"].pack("m0"))
  call.call("input", input, id: request_id)
  await_reminder { items.call.first.dig("terminal", "occurrences") == 2 }
  call.call("input", input, id: request_id)
  raise "Duplicate ACK replay rang again" unless items.call.first.dig("terminal", "occurrences") == 2
  checks << "duplicate_input_ack_does_not_duplicate_reminders"
  call.call("configureReminders", target.merge("reminderPolicy" => policy.merge("bells" => false)))
  line.call(%q{printf '\007\007'})
  raise "Disabled bells still changed inbox" unless items.call.first.dig("terminal", "occurrences") == 2
  checks << "updated_category_policy_applies_without_viewer"
  line.call(%q{printf '\033]777;MuseTerm;start=6d616b652074657374\007error: fixture\n\033]777;MuseTerm;end=2\007'})
  raise "Short explicit error did not create failed command reminder" unless items.call.count { |item| item["kind"] == "commandFailed" } == 1
  line.call(%q{printf '\033]777;MuseTerm;start=66616c7365\007error: ignored builtin\n\033]777;MuseTerm;end=1\007'})
  raise "Low-information command produced reminder" unless items.call.count { |item| item["kind"] == "commandFailed" } == 1
  line.call(%q{printf '\033]777;MuseTerm;start=6d616b65\007\033]0;error: hidden title\007\033]777;MuseTerm;end=2\007'})
  raise "Control string error text created failure evidence" unless items.call.count { |item| item["kind"] == "commandFailed" } == 1
  line.call(%q{printf '\033]777;MuseTerm;start=6d616b65\007\033]777;MuseTerm;end=0\007'})
  raise "Configured long completion threshold ignored" unless items.call.count { |item| item["kind"] == "commandCompleted" } == 1
  checks << "failure_error_evidence_low_information_filter_and_long_success_threshold"
  native = RuntimeWaitFileClient.new(root)
  list = native.request("list_attention", {"tab" => session.fetch("id")})
  raise "UI-independent list differs from service inbox" unless list["ok"] && list.fetch("attention").map { |item| item["id"] }.sort == items.call.map { |item| item["id"] }.sort
  checks << "readonly_native_list_uses_same_terminal_and_agent_inbox"
  items.call.each do |item|
    call.call("acknowledgeAttention", {"attentionID" => item.fetch("id"), "attentionVersion" => item.fetch("version")})
  end
  call.call("configureReminders", target.merge("reminderPolicy" => policy))
  grant = call.call("bindAgent", target.merge("agentKind" => "willdeep")).fetch("agentGrant")
  call.call("reportAgent", target.merge("agentReport" => grant.merge("sequence" => 1, "activity" => "working")))
  line.call(%q{printf '\007'})
  call.call("reportAgent", target.merge("agentReport" => grant.merge("sequence" => 2, "activity" => "blocked", "blockReason" => "approval")))
  line.call(%q{printf '\007'})
  raise "Native semantic approval duplicated by BEL" unless items.call.map { |item| item["kind"] } == ["approval"]
  checks << "native_agent_bells_do_not_duplicate_semantic_approval"
  # No viewer exists. A detached process can exit and produce its final pending item.
  exit_info = call.call("list").fetch("sessions").first
  call.call("input", target.merge("source" => "human", "inputSequence" => exit_info.fetch("nextInputSequence"), "data" => ["exit 0\n"].pack("m0")))
  client.close
  client = nil
  await_reminder do
    response = native.request("list_attention", {"tab" => session.fetch("id")})
    response.fetch("attention").count { |item| item["kind"] == "processExited" } == 1
  end
  checks << "process_exit_generates_one_reminder_with_all_socket_clients_absent"
  client = RuntimeProbeClient.new(root)
  call.call("close", target)
  raise "Closed terminal retained pending items" unless call.call("listAttention").fetch("attention").empty?
  call.call("shutdownIfEmpty")
  await_reminder { Process.waitpid(server, Process::WNOHANG) }
  raise "Service exit failed" unless $?.success?
  server = nil
rescue => error
  failure = "#{error.class}: #{error.message}"
ensure
  client&.close
  if server
    begin
      Process.kill("TERM", server)
      Process.waitpid(server)
    rescue Errno::ESRCH, Errno::ECHILD
      warn "Owned reminder fixture already exited"
    end
  end
  FileUtils.remove_entry(root)
end
result = {"generatedAt" => Time.now.iso8601, "version" => metadata && metadata["version"], "passed" => failure.nil?,
  "failure" => failure, "checks" => checks, "helperSHA256" => Digest::SHA256.file(binary).hexdigest,
  "scope" => "真实 PTY 普通提醒、资格规则、后台去重及无查看端列表；不包含系统通知投递和完整 GUI"}
File.write(prefix + ".json", JSON.pretty_generate(result) + "\n")
File.write(prefix + ".md", (["# 后台普通提醒", "", "通过：#{result['passed']}，检查：#{checks.length}", ""] + checks.map { |name| "- #{name}" } + ["", failure.to_s, "", result["scope"], ""]).join("\n"))
puts JSON.generate(result)
exit(failure ? 1 : 0)
