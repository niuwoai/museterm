#!/usr/bin/env ruby

require "fileutils"
require "open3"
require "pathname"
require "zlib"

ROOT = Pathname.new(__dir__).parent.freeze
SOURCE = ROOT.join("tools", "session-tunnel-helper").freeze
OUTPUT = ROOT.join("museterm", "SessionTunnelHelpers").freeze
TARGETS = [
  ["linux", "amd64"],
  ["linux", "arm64"],
  ["darwin", "amd64"],
  ["darwin", "arm64"]
].freeze

FileUtils.mkdir_p(OUTPUT)

TARGETS.each do |goos, goarch|
  name = "museterm-tunnel-#{goos}-#{goarch}"
  destination = OUTPUT.join(name)
  temporary = OUTPUT.join(".#{name}.tmp")
  environment = {
    "CGO_ENABLED" => "0",
    "GOOS" => goos,
    "GOARCH" => goarch
  }
  command = [
    "go", "build",
    "-trimpath",
    "-ldflags", "-s -w -buildid=",
    "-o", temporary.to_s,
    "."
  ]

  stdout, stderr, status = Open3.capture3(environment, *command, chdir: SOURCE.to_s)
  unless status.success?
    warn stdout unless stdout.empty?
    warn stderr unless stderr.empty?
    abort "failed to build #{goos}/#{goarch}"
  end

  FileUtils.chmod(0o755, temporary)
  FileUtils.mv(temporary, destination)
  Zlib::GzipWriter.open("#{destination}.gz") do |gzip|
    gzip.mtime = 0
    gzip.orig_name = ""
    File.open(destination, "rb") do |input|
      IO.copy_stream(input, gzip)
    end
  end
  puts "built #{destination.relative_path_from(ROOT)}"
end
