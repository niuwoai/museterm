#!/usr/bin/env ruby
# frozen_string_literal: true

# 把 npm/museterm 包发布到 npm。
#
#   ruby scripts/publish_npm_museterm.rb --version 1.256.0-rc4
#
# 只接受与 package.json、install-manifest.json 完全一致的版本。先确认 README 有内容，
# 再下载公开 CDN 上的命令行压缩包并核对 SHA256，最后执行 npm publish --tag rc。
# README 为空时拒绝发布：npmjs 上的说明页取的就是包里的 README。
# 仓库是私有的，GitHub Release 附件匿名下载会 404，所以压缩包放在 img.niuwoai.com。

require 'digest'
require 'json'
require 'net/http'
require 'open3'
require 'optparse'
require 'tmpdir'
require 'uri'

ROOT = File.expand_path('..', __dir__)
PACKAGE = File.join(ROOT, 'npm', 'museterm')
ASSET_NAME = 'museterm-cli-macos-universal.tar.gz'
ASSET_ENTRY = 'museterm'
README_MINIMUM_BYTES = 200
MAX_BYTES = 32 * 1024 * 1024
ASSET_BASE_URL = 'https://img.niuwoai.com/mac-apps/cli'
TRUSTED_HOSTS = %w[img.niuwoai.com].freeze

def read_json(path)
  # MCP 宿主不设 LANG，Ruby 会退回 US-ASCII，带中文的 package.json 直接读会报编码错误。
  JSON.parse(File.read(path, encoding: 'UTF-8'))
rescue JSON::ParserError, Errno::ENOENT => error
  abort "#{path} 无法读取：#{error.message}"
end

def trusted_redirect?(target)
  # URI 会把 https 的默认端口填成 443，显式非默认端口仍然拒绝。
  target.scheme == 'https' &&
    target.port == URI::HTTPS.default_port &&
    TRUSTED_HOSTS.include?(target.host)
end

def follow(uri, limit = 5)
  raise "重定向过多：#{uri}" if limit.negative?

  Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') do |http|
    response = http.request(Net::HTTP::Get.new(uri))
    return response unless response.is_a?(Net::HTTPRedirection)

    location = response['location']
    raise '空的重定向' if location.nil? || location.empty?

    target = URI.join(uri, location)
    raise "不受信任的重定向：#{target.host}" unless trusted_redirect?(target)

    follow(target, limit - 1)
  end
end

def require_readme
  path = File.join(PACKAGE, 'README.md')
  body = File.exist?(path) ? File.read(path, encoding: 'UTF-8') : ''
  text = body.gsub(/\s+/, ' ').strip
  abort 'README.md 没有内容，拒绝发布：npmjs 的说明页会是空的。' if text.bytesize < README_MINIMUM_BYTES
  abort 'README.md 没有标题，拒绝发布。' unless body.match?(/^#\s+\S/)
end

def verify_asset(manifest)
  uri = URI("#{ASSET_BASE_URL}/#{manifest['version']}/#{ASSET_NAME}")
  response = follow(uri)
  abort "#{ASSET_NAME} 下载失败：HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)
  body = response.body
  abort "#{ASSET_NAME} 超过 32 MiB" if body.bytesize > MAX_BYTES
  digest = Digest::SHA256.hexdigest(body)
  Dir.mktmpdir do |directory|
    archive = File.join(directory, ASSET_NAME)
    File.binwrite(archive, body)
    output = File.join(directory, 'out')
    Dir.mkdir(output)
    _out, err, status = Open3.capture3('tar', '-xzf', archive, '-C', output)
    abort "#{ASSET_NAME} 无法解压：#{err}" unless status.success?
    entries = Dir.children(output)
    abort "#{ASSET_NAME} 内容异常：#{entries.join(', ')}" unless entries == [ASSET_ENTRY]
    metadata = File.lstat(File.join(output, ASSET_ENTRY))
    abort "#{ASSET_NAME} 里的程序不是普通文件" unless metadata.file?
    abort "#{ASSET_NAME} 里的程序超过 32 MiB" if metadata.size > MAX_BYTES
    abort "#{ASSET_NAME} 里的程序不可执行" if (metadata.mode & 0o111).zero?
  end
  warn "#{ASSET_NAME} #{digest}"
  { ASSET_NAME => { 'name' => ASSET_NAME, 'sha256' => digest } }
end

def publish(version, dry_run: false)
  package = read_json(File.join(PACKAGE, 'package.json'))
  manifest = read_json(File.join(PACKAGE, 'install-manifest.json'))
  abort '版本不一致' unless [package['version'], manifest['version'], manifest['tag'].to_s.delete_prefix('v')].uniq == [version]
  abort '仓库不一致' unless manifest['repository'] == 'niuwoai/museterm'
  abort '包名不一致' unless package['name'] == '@niuwoai/museterm'
  require_readme
  manifest['assets'] = verify_asset(manifest)
  File.write(File.join(PACKAGE, 'install-manifest.json'), JSON.pretty_generate(manifest) + "\n") unless dry_run

  if dry_run
    warn 'dry-run：已核验 README 与发行包，不发布。'
    return
  end

  view_out, view_err, view_status = Open3.capture3('npm', 'view', "@niuwoai/museterm@#{version}", 'version', '--registry', 'https://registry.npmjs.org')
  if view_status.success? && view_out.strip == version
    warn "@niuwoai/museterm@#{version} 已存在，跳过发布。"
    return
  end
  abort "无法确认 npm 版本：#{view_err}" unless view_err.include?('E404')

  _out, err, status = Open3.capture3('npm', 'publish', '--access', 'public', '--tag', 'rc', '--registry', 'https://registry.npmjs.org', chdir: PACKAGE)
  abort "npm publish 失败：#{err}" unless status.success?
  warn "已发布 @niuwoai/museterm@#{version}（tag rc）"
end

if $PROGRAM_NAME == __FILE__
  options = { dry_run: false }
  OptionParser.new do |parser|
    parser.on('--version VERSION') { |value| options[:version] = value }
    parser.on('--dry-run') { options[:dry_run] = true }
  end.parse!
  abort '缺少 --version' unless options[:version]
  publish(options[:version], dry_run: options[:dry_run])
end
