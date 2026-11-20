#!/usr/bin/env ruby
# Counterfactual regression: keep one bounded output batch unread beyond the
# RPC deadline, then resume consumption without reconnecting or recreating PTY.
require "json"
require "base64"
require "tmpdir"
require "fileutils"
require "digest"
require "time"
require_relative "support/runtime_probe_client"

binary = File.expand_path(ARGV.fetch(0))
prefix = File.expand_path(ARGV.fetch(1))
root = Dir.mktmpdir("qrpause-", "/private/tmp")
File.chmod(0o700, root)
process = nil
reader = nil
passed = false
failure = nil
received = 0
diagnostics = []
begin
  process = Process.spawn(binary, "--root", root, in: File::NULL, out: File::NULL, err: File::NULL)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
  until File.socket?(File.join(root, "runtime.sock")) && File.file?(File.join(root, "ui-capability"))
    raise "Fixture service exited" if Process.waitpid(process, Process::WNOHANG)
    raise "Fixture startup timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    sleep 0.05
  end
  checked = lambda { |r| raise("Fixture request rejected: #{r['error']}") unless r["ok"]; r }
  creator = RuntimeProbeClient.new(root)
  fixture = "STDOUT.sync=true; sleep 0.5; STDOUT.write('x'*100_000); STDOUT.write('__CONSUMER_RESUMED__'); sleep 20"
  info = checked.call(creator.request("create", {"launch"=>{"executable"=>"/usr/bin/ruby", "arguments"=>["-e",fixture],
    "environment"=>{"PATH"=>"/usr/bin:/bin", "HOME"=>root}, "directory"=>root, "columns"=>80, "rows"=>24}})).fetch("session")
  creator.close
  reader = RuntimeProbeClient.new(root)
  reader.instance_variable_get(:@socket).setsockopt(Socket::SOL_SOCKET, Socket::SO_RCVBUF, 4096)
  first = checked.call(reader.request("subscribe", {"sessionID"=>info["id"], "generation"=>info["generation"]}))
  output = Base64.strict_decode64(first.fetch("data"))
  sleep 7
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
  until output.include?("__CONSUMER_RESUMED__")
    raise "Consumer did not resume" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    response = checked.call(reader.receive)
    raise "PTY identity changed" unless response.dig("session", "pid") == info["pid"] && response.dig("session", "generation") == info["generation"]
    output << Base64.strict_decode64(response.fetch("data"))
    received = output.bytesize
  end
  raise "Output was lost during pause" unless output.count("x") == 100_000
  passed = true
rescue StandardError => error
  failure = "#{error.class}: #{error.message}"
ensure
  reader&.close
  if process
    begin
      observer = RuntimeProbeClient.new(root)
      diagnostics = observer.request("diagnostics")["disconnects"] || []
      observer.close
    rescue StandardError => error
      failure ||= "Diagnostic read failed: #{error.class}"
      passed = false
    end
    begin
      unless Process.waitpid(process, Process::WNOHANG)
        Process.kill("TERM", process)
        Process.waitpid(process)
      end
    rescue Errno::ECHILD, Errno::ESRCH
      # Only the direct fixture child is eligible for cleanup.
    end
  end
  report = {"generatedAt"=>Time.now.iso8601, "passed"=>passed, "failure"=>failure, "pauseSeconds"=>7,
    "scope"=>"真实后台 PTY 与同一 Socket 订阅，100000 字节有界输出暂停 7 秒后继续读取；不等同 GUI 验收",
    "receivedBytes"=>received, "binarySHA256"=>Digest::SHA256.file(binary).hexdigest, "disconnects"=>diagnostics}
  File.write(prefix+".json", JSON.pretty_generate(report)+"\n")
  File.write(prefix+".md", "# 输出订阅暂停回归\n\n通过：#{passed}。暂停 7 秒，原 Socket 和 PTY 继续，收到 #{received} 字节。\n\n失败：#{failure || '无'}。\n")
  FileUtils.remove_entry(root)
end
puts JSON.generate({"passed"=>passed,"failure"=>failure,"report"=>prefix+".json"})
exit(passed ? 0 : 1)
