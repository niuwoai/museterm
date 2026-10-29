#!/usr/bin/env ruby
require "fileutils"
require "open3"
require "tmpdir"
require "json"
require "time"

root = File.expand_path("..", __dir__)
output = File.expand_path(ARGV.fetch(0))
architectures = ARGV.drop(1)
client_probe = architectures.delete("--client-probe")
architectures = [RUBY_PLATFORM.include?("arm64") ? "arm64" : "x86_64"] if architectures.empty?
abort "Unsupported architecture" unless (architectures - %w[arm64 x86_64]).empty?
FileUtils.mkdir_p(File.dirname(output))
# Xcode grants script scratch access to TEMP_DIR, but independently denies
# DERIVED_FILE_DIR descendants unless each output is declared. A directory
# output is only a literal allowance, so dynamic module-cache/lock children
# must live in the target's script scratch area rather than DerivedSources.
scratch_root = ENV["TEMP_DIR"] || ENV["DERIVED_FILE_DIR"]
build_root = scratch_root ? File.join(scratch_root, "MuseTermRuntimeBuild") : "/private/tmp/museterm-runtime-build-#{Process.uid}"
FileUtils.mkdir_p(build_root, mode: 0o700)
attributes = File.lstat(build_root)
abort "Runtime cache root must be an owned directory" unless attributes.directory? && !attributes.symlink? && attributes.uid == Process.uid
File.chmod(0o700, build_root)
cache_lock = File.open(File.join(build_root, "build.lock"), File::RDWR | File::CREAT | File::NOFOLLOW, 0o600)
abort "Runtime cache lock must be a private owned file" unless cache_lock.stat.file? && cache_lock.stat.uid == Process.uid && cache_lock.stat.mode & 0o077 == 0
cache_lock.flock(File::LOCK_EX)
measurements = []
Dir.mktmpdir("museterm-runtime-build-", build_root) do |temporary|
  binaries = architectures.map do |architecture|
    object = File.join(temporary, "pty-#{architecture}.o")
    binary = File.join(temporary, "runtime-#{architecture}")
    commands = []
    unless client_probe
      commands << ["xcrun", "clang", "-arch", architecture, "-mmacosx-version-min=13.0", "-Wall", "-Wextra", "-Werror", "-c",
        File.join(root, "tools/terminal-runtime/PTY.c"), "-o", object]
    end
    sources = client_probe ? [File.join(root, "museterm/TerminalRuntimeConnection.swift"), File.join(root, "scripts/verify_terminal_runtime_client.swift")] : Dir.glob(File.join(root, "tools/terminal-runtime/*.swift")).sort
    bridge = client_probe ? [] : ["-import-objc-header", File.join(root, "tools/terminal-runtime/PTY.h")]
    module_cache = File.join(build_root, "ModuleCache-#{architecture}")
    cache_existed = File.directory?(module_cache)
    commands << ["xcrun", "swiftc", "-target", "#{architecture}-apple-macosx13.0", "-O", "-parse-as-library",
        "-module-cache-path", module_cache, *bridge,
        *%w[AppVersion.swift TerminalRuntimeProtocol.swift TerminalRuntimeReplyPolicy.swift TerminalRuntimeOutputJournal.swift TerminalAgentState.swift
          TerminalCommandLifecycleState.swift TerminalReminderPolicy.swift TerminalOutputInsights.swift TerminalRuntimeCommand.swift TerminalShellReportedContext.swift
          TerminalShellIntegrationParser.swift TerminalSessionEventJournal.swift TerminalAttentionContext.swift
          TerminalAttentionStore.swift TerminalNativeAgentContext.swift TerminalWaitTypes.swift TerminalWaitCoordinator.swift].map { |name| File.join(root, "museterm", name) },
        *sources, *(client_probe ? [] : [object]), "-o", binary]
    commands.each do |command|
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      stdout, stderr, status = Open3.capture3(*command)
      measurements << {"architecture" => architecture, "stage" => command[1], "seconds" => Process.clock_gettime(Process::CLOCK_MONOTONIC) - started,
        "exitCode" => status.exitstatus, "moduleCacheExisted" => cache_existed, "moduleCache" => module_cache}
      abort "Runtime build failed:\n#{stdout}\n#{stderr}" unless status.success?
    end
    binary
  end
  if binaries.length == 1
    signed_binary = binaries.first
  else
    signed_binary = File.join(temporary, "runtime-universal")
    _, error, status = Open3.capture3("xcrun", "lipo", "-create", *binaries, "-output", signed_binary)
    abort error unless status.success?
  end
  # codesign creates temporary sibling files. Sign inside the recursively
  # writable scratch directory before copying to Xcode's literal output path.
  File.chmod(0o755, signed_binary)
  identity = ENV["EXPANDED_CODE_SIGN_IDENTITY"]
  if ENV["CODE_SIGNING_ALLOWED"] == "YES" && identity && !identity.empty?
    command = ["/usr/bin/codesign", "--force", "--sign", identity]
    command += identity == "-" ? ["--timestamp=none"] : ["--options", "runtime", "--timestamp"]
    _, error, status = Open3.capture3(*command, signed_binary)
    abort "Runtime signing failed: #{error}" unless status.success?
  end
  FileUtils.cp(signed_binary, output)
end
cache_lock.close
File.chmod(0o755, output)
puts "Built #{output} (#{architectures.join(', ')})"
if (prefix = ENV["MUSETERM_RUNTIME_BUILD_REPORT"])
  report = {"generatedAt" => Time.now.iso8601, "scope" => "helper compilation only; not test, signing or release acceleration", "measurements" => measurements}
  FileUtils.mkdir_p(File.dirname(prefix))
  File.write(prefix + ".json", JSON.pretty_generate(report) + "\n")
  lines = ["# Terminal helper compilation", "", "| Architecture | Stage | Seconds | Existing module cache | Exit |", "|---|---|---:|---|---:|"]
  measurements.each { |row| lines << "| #{row['architecture']} | #{row['stage']} | #{row['seconds'].round(3)} | #{row['moduleCacheExisted']} | #{row['exitCode']} |" }
  File.write(prefix + ".md", lines.join("\n") + "\n")
end
