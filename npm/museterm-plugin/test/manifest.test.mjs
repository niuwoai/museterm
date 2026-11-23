import assert from "node:assert/strict"
import { test } from "node:test"

import {
  checkPluginPackage,
  definePlugin,
  pluginCommandID,
  versionRangeCovers,
} from "../dist/index.js"

const localized = (en, hans) => ({ en, "zh-Hans": hans })

function command(overrides = {}) {
  return {
    id: "staging",
    title: localized("Deploy staging", "部署到预发"),
    subtitle: localized("Fill a deploy command", "填入部署命令"),
    symbol: "shippingbox",
    priority: 100,
    export: "deployStaging",
    ...overrides,
  }
}

function manifest(overrides = {}) {
  return {
    schemaVersion: 1,
    engines: { museterm: ">=1.262.0" },
    entry: "dist/index.js",
    displayName: localized("Deploy", "部署"),
    permissions: ["palette", "terminal.fill"],
    commands: [command()],
    ...overrides,
  }
}

function packageFor(museterm, overrides = {}) {
  return {
    name: "@example/museterm-deploy",
    version: "0.1.0",
    museterm,
    ...overrides,
  }
}

function paths(issues) {
  return issues.map((issue) => issue.path)
}

test("接受规划文档里的示例清单", () => {
  assert.deepEqual(checkPluginPackage(packageFor(manifest())), [])
})

test("拒绝缺字段、缺中文、非法权限和错误的 schemaVersion", () => {
  const cases = [
    ["缺 schemaVersion", manifest({ schemaVersion: undefined }), "/museterm"],
    ["缺中文", manifest({
      displayName: { en: "Deploy" },
    }), "/museterm/displayName"],
    ["非法权限", manifest({
      permissions: ["palette", "pty.read"],
    }), "/museterm/permissions/1"],
    ["错误的 schemaVersion", manifest({ schemaVersion: 2 }), "/museterm/schemaVersion"],
  ]

  for (const [name, value, path] of cases) {
    const issues = checkPluginPackage(packageFor(value))
    assert.ok(issues.length > 0, name)
    assert.ok(paths(issues).includes(path), `${name}: ${JSON.stringify(issues)}`)
  }
})

test("拒绝额外字段、空命令、越界优先级、重复权限和非法标识", () => {
  const cases = [
    manifest({ store: true }),
    manifest({ commands: [] }),
    manifest({ commands: [command({ priority: 900 })] }),
    manifest({ permissions: ["palette", "palette"] }),
    manifest({ commands: [command({ id: "Deploy" })] }),
    manifest({ commands: [command({ export: "deploy-staging" })] }),
  ]
  for (const value of cases) {
    assert.ok(checkPluginPackage(packageFor(value)).length > 0, JSON.stringify(value))
  }
})

test("命令必须带 palette，AI 和录制必须带各自的权限", () => {
  assert.ok(paths(checkPluginPackage(packageFor(manifest({
    permissions: ["terminal.fill"],
  })))).includes("/museterm/permissions"))

  assert.ok(paths(checkPluginPackage(packageFor(manifest({
    permissions: ["palette"],
    ai: { suggest: "suggest" },
  })))).includes("/museterm/ai"))

  assert.ok(paths(checkPluginPackage(packageFor(manifest({
    permissions: ["palette"],
    recording: { onFinished: "onRecording" },
  })))).includes("/museterm/recording"))
})

test("重复的命令、导出和偏好名称会被拒绝", () => {
  const duplicated = manifest({
    commands: [command(), command({ export: "other" })],
    preferences: [
      {
        name: "region",
        type: "text",
        title: localized("Region", "区域"),
      },
      {
        name: "region",
        type: "text",
        title: localized("Region", "区域"),
      },
    ],
  })
  const found = paths(checkPluginPackage(packageFor(duplicated)))
  assert.ok(found.includes("/museterm/commands"))
  assert.ok(found.includes("/museterm/preferences"))
})

test("下拉偏好必须有选项，默认值必须是其中之一", () => {
  const missing = manifest({
    preferences: [{
      name: "region",
      type: "dropdown",
      title: localized("Region", "区域"),
    }],
  })
  assert.ok(checkPluginPackage(packageFor(missing)).length > 0)

  const unknown = manifest({
    preferences: [{
      name: "region",
      type: "dropdown",
      title: localized("Region", "区域"),
      data: [{ title: localized("East", "东"), value: "east" }],
      default: "west",
    }],
  })
  assert.ok(paths(checkPluginPackage(packageFor(unknown))).includes(
    "/museterm/preferences/0/default",
  ))
})

test("拒绝生命周期脚本和本地或 git 依赖", () => {
  assert.ok(paths(checkPluginPackage(packageFor(manifest(), {
    scripts: { postinstall: "node install.js" },
  }))).includes("/scripts"))

  for (const spec of ["file:../other", "git+https://example.com/plugin.git", "github:example/plugin"]) {
    const issues = checkPluginPackage(packageFor(manifest(), {
      dependencies: { other: spec },
    }))
    assert.ok(paths(issues).includes("/dependencies/other"), spec)
  }
})

test("版本范围按正式版高于同号 rc 比较", () => {
  assert.equal(versionRangeCovers(">=1.262.0-rc2", "1.262.0-rc2"), true)
  assert.equal(versionRangeCovers(">=1.262.0-rc2", "1.262.0-rc3"), true)
  assert.equal(versionRangeCovers(">=1.262.0-rc2", "1.262.0"), true)
  assert.equal(versionRangeCovers(">=1.262.0", "1.262.0-rc2"), false)
  assert.equal(versionRangeCovers("1.262.0-rc2", "1.262.0-rc2"), true)
  assert.equal(versionRangeCovers("1.262.0-rc2", "1.262.0-rc3"), false)
  assert.equal(versionRangeCovers("*", "1.262.0-rc2"), true)
  assert.equal(versionRangeCovers(">1.262.0", "1.262.0"), null)
  assert.equal(versionRangeCovers(">=1.262.0 || >=1.263.0", "1.262.0"), null)

  const tooOld = checkPluginPackage(packageFor(manifest()), { appVersion: "1.262.0-rc2" })
  assert.ok(paths(tooOld).includes("/museterm/engines/museterm"))
  const covered = checkPluginPackage(packageFor(manifest({
    engines: { museterm: ">=1.262.0-rc2" },
  })), { appVersion: "1.262.0-rc2" })
  assert.deepEqual(covered, [])
})

test("命令标识带包名命名空间", () => {
  assert.equal(
    pluginCommandID("@example/museterm-deploy", "staging"),
    "plugin:@example__museterm-deploy:staging",
  )
})

test("definePlugin 只校验清单，不连接应用", () => {
  assert.equal(definePlugin(manifest()).schemaVersion, 1)
  assert.throws(() => definePlugin(manifest({ schemaVersion: 2 })), /schemaVersion/)
})
