#!/usr/bin/env ruby
# frozen_string_literal: true

# npm 安装包的离线契约测试。
#
#   ruby scripts/test/npm_museterm_test.rb
#
# 不访问 GitHub、不执行 npm publish。测试用本地假 HTTP 服务和假发行包钉住平台选择、
# SHA256、压缩包边界、下载失败、重复安装，以及 README 必须有内容。

require 'digest'
require 'fileutils'
require 'json'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require 'webrick'

ROOT = File.expand_path('../..', __dir__)
PACKAGE = File.join(ROOT, 'npm', 'museterm')
ASSET = 'museterm-cli-macos-universal.tar.gz'

class NpmMusetermTest < Minitest::Test
  def setup
    @server = nil
  end

  def teardown
    @server&.shutdown
  end

  def test_postinstall_waits_for_failure_and_exits_nonzero
    Dir.mktmpdir do |directory|
      copy_package(directory)
      File.write(File.join(directory, 'install-manifest.json'), '{')
      _out, err, status = Open3.capture3('node', 'lib/install.js', chdir: directory)
      refute status.success?
      assert_includes utf8(err), 'SyntaxError'
    end
  end

  def test_manifest_matches_package_and_release_names
    package = JSON.parse(File.read(File.join(PACKAGE, 'package.json'), encoding: 'UTF-8'))
    manifest = JSON.parse(File.read(File.join(PACKAGE, 'install-manifest.json'), encoding: 'UTF-8'))
    assert_equal '@niuwoai/museterm', package['name']
    assert_equal package['version'], manifest['version']
    assert_equal "v#{package['version']}", manifest['tag']
    assert_equal 'niuwoai/museterm', manifest['repository']
    assert_equal({ 'museterm' => 'bin/museterm.js' }, package['bin'])
    assert_equal 'rc', package.dig('publishConfig', 'tag')
    assert_includes package['files'], 'README.md'
  end

  def test_readme_has_content_for_the_registry_page
    readme = File.read(File.join(PACKAGE, 'README.md'), encoding: 'UTF-8')
    text = readme.gsub(/\s+/, ' ').strip
    assert_operator text.bytesize, :>=, 200, 'README 太短，npmjs 说明页会看起来是空的'
    assert_match(/^#\s+\S/, readme)
    assert_includes readme, 'npm install -g @niuwoai/museterm@rc'
    assert_includes readme, 'museterm mcp'
  end

  def test_publish_script_refuses_an_empty_readme
    Dir.mktmpdir do |directory|
      copy_package(directory)
      File.write(File.join(directory, 'README.md'), "# 标题\n\n太短。\n")
      script = publish_script_for(directory)
      _out, err, status = Open3.capture3({ 'RUBYOPT' => '-EUTF-8' }, 'ruby', script, '--version', '1.256.0-rc4', '--dry-run')
      refute status.success?
      assert_includes utf8(err), 'README.md 没有内容'
    end
  end

  def test_install_verifies_archive_and_reuses_exact_binary
    binary = File.binread('/bin/echo')
    archive = Dir.mktmpdir do |directory|
      File.write(File.join(directory, 'museterm'), binary, perm: 0o755)
      _out, err, status = Open3.capture3('tar', '-czf', 'asset.tar.gz', 'museterm', chdir: directory)
      flunk(err) unless status.success?
      File.binread(File.join(directory, 'asset.tar.gz'))
    end
    digest = Digest::SHA256.hexdigest(archive)
    serve(ASSET => archive)

    Dir.mktmpdir do |directory|
      copy_package(directory)
      File.write(File.join(directory, 'install-manifest.json'), JSON.generate(manifest_for(digest)))
      out, err, status = run_installer(directory, 'darwin', 'arm64')
      assert status.success?, "#{out}\n#{err}"
      installed = File.join(directory, 'bin', 'museterm')
      assert_equal binary, File.binread(installed)
      assert_equal 0o755, File.stat(installed).mode & 0o777

      File.write(installed, 'changed')
      second_out, second_err, second_status = run_installer(directory, 'darwin', 'arm64')
      assert second_status.success?, "#{second_out}\n#{second_err}"
      assert_equal 'changed', File.read(installed), '同版本同校验值不得覆盖已安装程序'
    end
  end

  def test_wrong_digest_archive_shape_and_unsupported_platform_fail
    Dir.mktmpdir do |directory|
      copy_package(directory)
      File.write(File.join(directory, 'museterm'), 'x', perm: 0o755)
      File.write(File.join(directory, 'extra'), 'y')
      _out, err, status = Open3.capture3('tar', '-czf', 'bad.tar.gz', 'museterm', 'extra', chdir: directory)
      flunk(err) unless status.success?
      archive = File.binread(File.join(directory, 'bad.tar.gz'))
      serve(ASSET => archive)
      File.write(File.join(directory, 'install-manifest.json'), JSON.generate(manifest_for('0' * 64)))

      _out, err, status = run_installer(directory, 'darwin', 'arm64')
      refute status.success?
      assert_includes utf8(err), 'SHA256'

      File.write(File.join(directory, 'install-manifest.json'), JSON.generate(manifest_for(Digest::SHA256.hexdigest(archive))))
      _out, err, status = run_installer(directory, 'darwin', 'arm64')
      refute status.success?
      assert_includes utf8(err), '内容异常'

      _out, err, status = run_installer(directory, 'linux', 'x64')
      refute status.success?
      assert_includes utf8(err), '暂不支持'
    end
  end

  def test_symlink_archive_is_rejected
    Dir.mktmpdir do |directory|
      copy_package(directory)
      File.symlink('/bin/echo', File.join(directory, 'museterm'))
      _out, err, status = Open3.capture3('tar', '-czf', 'link.tar.gz', 'museterm', chdir: directory)
      flunk(err) unless status.success?
      archive = File.binread(File.join(directory, 'link.tar.gz'))
      serve(ASSET => archive)
      File.write(File.join(directory, 'install-manifest.json'), JSON.generate(manifest_for(Digest::SHA256.hexdigest(archive))))
      _out, err, status = run_installer(directory, 'darwin', 'x64')
      refute status.success?
      assert_includes utf8(err), '普通文件'
    end
  end

  def test_redirect_limit_and_malformed_manifest_fail_closed
    oversized = 'x' * 1024
    serve(ASSET => oversized)
    @server.mount_proc('/redirect') { |_request, response| response.status = 302; response['Location'] = '/redirect' }
    Dir.mktmpdir do |directory|
      copy_package(directory)
      manifest = manifest_for(Digest::SHA256.hexdigest(oversized))
      manifest['repository'] = 'example.test/../redirect'
      File.write(File.join(directory, 'install-manifest.json'), JSON.generate(manifest))
      _out, err, status = run_installer(directory, 'darwin', 'arm64')
      refute status.success?
      assert_includes utf8(err), '安装清单不完整'

      manifest['repository'] = 'example.test/museterm'
      manifest['assets'][ASSET]['sha256'] = 'not-a-digest'
      File.write(File.join(directory, 'install-manifest.json'), JSON.generate(manifest))
      _out, err, status = run_installer(directory, 'darwin', 'arm64')
      refute status.success?
      assert_includes utf8(err), '校验值'

      @server.mount_proc("/mac-apps/cli/1.256.0-rc4/#{ASSET}") do |_request, response|
        response.status = 302
        response['Location'] = 'https://img.niuwoai.com:8443/unrelated'
      end
      File.write(File.join(directory, 'install-manifest.json'), JSON.generate(manifest_for(Digest::SHA256.hexdigest('x'))))
      _out, err, status = run_installer(directory, 'darwin', 'arm64')
      refute status.success?
      assert_includes utf8(err), '不受信任'
    end
  end

  private

  def utf8(text)
    text.to_s.dup.force_encoding(Encoding::UTF_8)
  end

  def copy_package(directory)
    FileUtils.cp_r(Dir[File.join(PACKAGE, '*')], directory)
  end

  def manifest_for(digest)
    {
      'version' => '1.256.0-rc4',
      'repository' => 'example.test/museterm',
      'tag' => 'v1.256.0-rc4',
      'assets' => {
        ASSET => { 'name' => ASSET, 'sha256' => digest }
      }
    }
  end

  def serve(files)
    @server = WEBrick::HTTPServer.new(Port: 0, Logger: WEBrick::Log.new(File::NULL), AccessLog: [])
    files.each do |name, body|
      @server.mount_proc("/mac-apps/cli/1.256.0-rc4/#{name}") do |_request, response|
        response.status = 200
        response['Content-Type'] = 'application/octet-stream'
        response.body = body
      end
    end
    Thread.new { @server.start }
  end

  def run_installer(directory, platform, arch)
    script = <<~'JS'
      const { installMuseterm } = require('./lib/release');
      const fs = require('node:fs');
      const manifest = JSON.parse(fs.readFileSync('install-manifest.json', 'utf8'));
      const base = `http://127.0.0.1:${process.argv[3]}`;
      const fetchImpl = (url, options) => fetch(url.replace('https://img.niuwoai.com', base), options);
      installMuseterm({
        manifest,
        platform: process.argv[1],
        arch: process.argv[2],
        destination: require('node:path').join(process.cwd(), 'bin', 'museterm'),
        packageRoot: process.cwd(),
        fetchImpl,
        trustedHosts: new Set(['127.0.0.1']),
      }).catch((error) => {
        process.stderr.write(`${error.stack}\n`);
        process.exit(1);
      });
    JS
    Open3.capture3('node', '-e', script, platform, arch, @server.config[:Port].to_s, chdir: directory)
  end

  def publish_script_for(package_directory)
    source = File.read(File.join(ROOT, 'scripts', 'publish_npm_museterm.rb'), encoding: 'UTF-8')
    patched = source.sub("File.join(ROOT, 'npm', 'museterm')", "'#{package_directory}'")
    path = File.join(package_directory, 'publish.rb')
    File.write(path, patched)
    path
  end
end
