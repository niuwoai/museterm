#!/usr/bin/env ruby
require "json"
require "tmpdir"
require "fileutils"
require "open3"
require "time"

builder = File.expand_path("build_terminal_runtime.rb", __dir__)
prefix = File.expand_path(ARGV.fetch(0, "/private/tmp/qterm-runtime-build-contract"))
results = []
Dir.mktmpdir("qrt-build-contract-", "/private/tmp") do |root|
  output = File.join(root, "runtime")
  sentinel = "existing-artifact-must-not-be-overwritten"
  File.write(output, sentinel)
  run = lambda do |name, derived, architecture, &predicate|
    stdout, stderr, status = Open3.capture3({"DERIVED_FILE_DIR" => derived}, RbConfig.ruby, builder, output, architecture)
    passed = !status.success? && File.read(output) == sentinel && predicate.call(stdout + stderr)
    results << {"name" => name, "passed" => passed, "exitCode" => status.exitstatus}
  end
  run.call("unsupported_architecture_preserves_existing_artifact", File.join(root, "unused"), "unsupported") { |message| message.include?("Unsupported architecture") }

  victim = File.join(root, "victim")
  FileUtils.mkdir_p(victim, mode: 0o700)
  derived = File.join(root, "derived-symlink")
  FileUtils.mkdir_p(derived)
  File.symlink(victim, File.join(derived, "QTermRuntimeBuild"))
  run.call("cache_root_symlink_is_rejected_before_compilation", derived, "arm64") { |message| message.include?("Runtime cache root must be an owned directory") }

  derived = File.join(root, "derived-lock")
  cache = File.join(derived, "QTermRuntimeBuild")
  FileUtils.mkdir_p(cache, mode: 0o700)
  protected = File.join(root, "protected")
  File.write(protected, sentinel)
  File.symlink(protected, File.join(cache, "build.lock"))
  run.call("cache_lock_symlink_cannot_overwrite_another_file", derived, "arm64") { |message| message.include?("ELOOP") || message.include?("Too many levels") }
  results.last["passed"] &&= File.read(protected) == sentinel
end
passed = results.all? { |result| result.fetch("passed") }
report = {"generatedAt" => Time.now.iso8601, "passed" => passed, "results" => results,
  "scope" => "build script rejection and cache path contracts; does not replace real compilation or release verification"}
FileUtils.mkdir_p(File.dirname(prefix))
File.write(prefix + ".json", JSON.pretty_generate(report) + "\n")
lines = ["# Runtime build contracts", "", "Passed: #{passed}", ""] + results.map { |result| "- #{result['name']}: #{result['passed']}" }
File.write(prefix + ".md", lines.join("\n") + "\n")
puts JSON.generate({"passed" => passed, "tests" => results.length, "report" => prefix + ".json"})
exit(passed ? 0 : 1)
