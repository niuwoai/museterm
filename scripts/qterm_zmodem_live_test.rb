#!/usr/bin/env ruby

require "digest"
require "fileutils"
require "json"
require "open3"
require "securerandom"
require "shellwords"
require "time"
require "timeout"
require "tmpdir"

TARGET = ARGV.fetch(0, "root@h1.niuwoai.com")
REPORT_JSON = File.expand_path("../reports/qterm_zmodem_live_test.json", __dir__)
REPORT_MARKDOWN = File.expand_path("../reports/qterm_zmodem_live_test.md", __dir__)
TIMEOUT_SECONDS = 45

def capture!(*command)
  output, error, status = Open3.capture3(*command)
  raise "#{command.first} failed: #{error.strip}" unless status.success?
  output.strip
end

def bridge_zmodem(local_command:, remote_command:, local_directory: nil)
  remote_error = +""
  local_error = +""
  remote_status = nil
  local_status = nil
  Timeout.timeout(TIMEOUT_SECONDS) do
    Open3.popen3("ssh", "-o", "BatchMode=yes", TARGET, remote_command) do |remote_in, remote_out, remote_err, remote_wait|
      options = {}
      options[:chdir] = local_directory if local_directory
      Open3.popen3(*local_command, **options) do |local_in, local_out, local_err, local_wait|
        pumps = [
          Thread.new { IO.copy_stream(remote_out, local_in) rescue nil; local_in.close rescue nil },
          Thread.new { IO.copy_stream(local_out, remote_in) rescue nil; remote_in.close rescue nil },
          Thread.new { remote_error << remote_err.read },
          Thread.new { local_error << local_err.read }
        ]
        local_status = local_wait.value
        remote_status = remote_wait.value
        pumps.each(&:join)
      end
    end
  end
  {
    local_exit: local_status&.exitstatus,
    remote_exit: remote_status&.exitstatus,
    local_stderr: local_error.strip,
    remote_stderr: remote_error.strip
  }
end

started_at = Time.now.utc
run_id = SecureRandom.hex(8)
remote_directory = "/tmp/qterm-zmodem-live-#{run_id}"
local_directory = File.join(Dir.tmpdir, "qterm-zmodem-live-#{run_id}")
upload_file = File.join(local_directory, "upload.bin")
download_file = File.join(local_directory, "download", "upload.bin")
results = []

begin
  FileUtils.mkdir_p(File.dirname(download_file))
  File.binwrite(upload_file, SecureRandom.random_bytes(256 * 1024))
  local_hash = Digest::SHA256.file(upload_file).hexdigest
  capture!("ssh", "-o", "BatchMode=yes", TARGET, "mkdir -p #{Shellwords.escape(remote_directory)}")

  upload = bridge_zmodem(
    local_command: ["sz", "-b", upload_file],
    remote_command: "cd #{Shellwords.escape(remote_directory)} && rz -E"
  )
  remote_hash = capture!(
    "ssh", "-o", "BatchMode=yes", TARGET,
    "sha256sum #{Shellwords.escape("#{remote_directory}/upload.bin")} | awk '{print $1}'"
  )
  upload_ok = upload[:local_exit] == 0 && upload[:remote_exit] == 0 && remote_hash == local_hash
  results << upload.merge(
    name: "rz_upload",
    ok: upload_ok,
    bytes: File.size(upload_file),
    local_sha256: local_hash,
    remote_sha256: remote_hash
  )

  download = bridge_zmodem(
    local_command: ["rz", "-E"],
    remote_command: "sz -e -- #{Shellwords.escape("#{remote_directory}/upload.bin")}",
    local_directory: File.dirname(download_file)
  )
  download_hash = File.file?(download_file) ? Digest::SHA256.file(download_file).hexdigest : nil
  download_ok = download[:local_exit] == 0 && download[:remote_exit] == 0 && download_hash == local_hash
  results << download.merge(
    name: "sz_download",
    ok: download_ok,
    bytes: File.file?(download_file) ? File.size(download_file) : 0,
    remote_sha256: local_hash,
    local_sha256: download_hash
  )
ensure
  capture!("ssh", "-o", "BatchMode=yes", TARGET, "rm -rf -- #{Shellwords.escape(remote_directory)}") rescue nil
  FileUtils.rm_rf(local_directory)
end

report = {
  target: TARGET,
  started_at: started_at.iso8601,
  finished_at: Time.now.utc.iso8601,
  ok: results.all? { |result| result[:ok] },
  scope: "direct SSH PTY/ZMODEM transport harness",
  results: results
}
FileUtils.mkdir_p(File.dirname(REPORT_JSON))
File.write(REPORT_JSON, JSON.pretty_generate(report) + "\n")
markdown = [
  "# QTerm ZMODEM Live Test",
  "",
  "- Target: `#{TARGET}`",
  "- Scope: direct SSH PTY/ZMODEM transport harness (`sz` ↔ remote `rz`, remote `sz` ↔ local `rz`)",
  "- Result: **#{report[:ok] ? "PASS" : "FAIL"}**",
  "- Started: `#{report[:started_at]}`",
  "- Finished: `#{report[:finished_at]}`",
  "",
  "| Case | Result | Bytes | Local exit | Remote exit | SHA-256 matched |",
  "|---|---:|---:|---:|---:|---:|"
]
results.each do |result|
  markdown << "| #{result[:name]} | #{result[:ok] ? "PASS" : "FAIL"} | #{result[:bytes]} | #{result[:local_exit]} | #{result[:remote_exit]} | #{result[:local_sha256] == result[:remote_sha256]} |"
end
File.write(REPORT_MARKDOWN, markdown.join("\n") + "\n")
puts JSON.pretty_generate(report)
exit(report[:ok] ? 0 : 1)
