import { readFileSync } from "node:fs"

import { Ajv2020, type ErrorObject, type ValidateFunction } from "ajv/dist/2020.js"

/** Permissions a plugin may declare. There is no screen, network, or keychain permission. */
export const pluginPermissions = [
  "palette",
  "terminal.fill",
  "ai.suggest",
  "recording.observe",
] as const

export type PluginPermission = (typeof pluginPermissions)[number]

export const manifestSchemaVersion = 1

/** Highest priority a plugin command may take. Built-in palette rows stay above it. */
export const maximumCommandPriority = 380

export interface LocalizedText {
  en: string
  "zh-Hans": string
}

export interface PluginCommand {
  id: string
  title: LocalizedText
  subtitle?: LocalizedText
  symbol?: string
  priority?: number
  export: string
}

export interface PluginPreferenceChoice {
  title: LocalizedText
  value: string
}

interface PluginPreferenceBase {
  name: string
  title: LocalizedText
  description?: LocalizedText
  required?: boolean
}

export type PluginPreference =
  | (PluginPreferenceBase & {
      type: "text"
      default?: string
    })
  | (PluginPreferenceBase & {
      type: "boolean"
      default?: boolean
    })
  | (PluginPreferenceBase & {
      type: "dropdown"
      data: readonly PluginPreferenceChoice[]
      default?: string
    })

/** The `museterm` field of a plugin package.json. */
export interface PluginManifest {
  schemaVersion: typeof manifestSchemaVersion
  engines: {
    museterm: string
  }
  entry: string
  displayName: LocalizedText
  permissions: PluginPermission[]
  commands: PluginCommand[]
  preferences?: PluginPreference[]
  ai?: {
    suggest: string
  }
  recording?: {
    onFinished: string
  }
}

export interface PluginPackage {
  name: string
  version: string
  museterm: PluginManifest
}

export interface ManifestIssue {
  path: string
  message: string
}

export interface CheckPluginPackageOptions {
  /** When set, `engines.museterm` must cover this application version. */
  appVersion?: string
}

interface ParsedVersion {
  major: number
  minor: number
  patch: number
  rc: number | null
}

const schema = JSON.parse(
  readFileSync(new URL("../schema/manifest.schema.json", import.meta.url), "utf8"),
) as object

const ajv = new Ajv2020({
  allErrors: true,
  strict: true,
})
const validateManifest = ajv.compile(schema) as ValidateFunction<PluginManifest>

const packageNamePattern = /^(?:@[a-z0-9][a-z0-9._-]*\/)?[a-z0-9][a-z0-9._-]*$/
const versionPattern = /^(\d+)\.(\d+)\.(\d+)(?:-rc(\d+))?$/
const lifecycleScripts = ["preinstall", "install", "postinstall", "prepare"]
const dependencyFields = ["dependencies", "devDependencies", "optionalDependencies"]
const remoteDependencyPattern = /^(?:file:|link:|git\+|git:|github:|gitlab:|bitbucket:)/

/**
 * Checks a package.json value against the manifest schema and the host rules
 * JSON Schema cannot express. An empty list means the package can be installed.
 * This does not read a plugin directory, start a process, or contact the app.
 */
export function checkPluginPackage(
  value: unknown,
  options: CheckPluginPackageOptions = {},
): ManifestIssue[] {
  if (!isRecord(value)) {
    return [{ path: "", message: "package.json 必须是对象" }]
  }

  const issues: ManifestIssue[] = []
  if (!isNonEmptyString(value.name) || !packageNamePattern.test(value.name)) {
    issues.push({ path: "/name", message: "包名必须是合法的 npm 包名" })
  }
  if (!isNonEmptyString(value.version)) {
    issues.push({ path: "/version", message: "必须有版本号" })
  }
  if (hasLifecycleScripts(value.scripts)) {
    issues.push({
      path: "/scripts",
      message: "不能带 preinstall、install、postinstall 或 prepare",
    })
  }
  issues.push(...dependencyIssues(value))

  const manifest: unknown = value.museterm
  if (!validateManifest(manifest)) {
    issues.push(...schemaIssues(validateManifest.errors))
    return issues
  }

  issues.push(...permissionIssues(manifest))
  issues.push(...duplicateIssues(manifest))
  issues.push(...dropdownDefaultIssues(manifest))
  issues.push(...engineIssues(manifest, options.appVersion))
  return issues
}

/**
 * Returns the manifest when it passes every check, otherwise throws with every
 * issue. It does not connect to MuseTerm and does not register anything.
 */
export function definePlugin(manifest: PluginManifest): PluginManifest {
  const issues = checkPluginPackage({
    name: "@example/museterm-plugin",
    version: "0.0.0",
    museterm: manifest,
  }).filter((issue) => issue.path === "/museterm" || issue.path.startsWith("/museterm/"))
  if (issues.length > 0) {
    throw new Error(issues.map((issue) => `${issue.path} ${issue.message}`).join("\n"))
  }
  return manifest
}

/** The command palette identifier. A slash in the package name becomes `__`. */
export function pluginCommandID(packageName: string, commandID: string): string {
  return `plugin:${packageName.replaceAll("/", "__")}:${commandID}`
}

/** The schema shipped with this package. A future host reads the same file. */
export function pluginManifestSchema(): unknown {
  return schema
}

function permissionIssues(manifest: PluginManifest): ManifestIssue[] {
  const issues: ManifestIssue[] = []
  const granted = new Set(manifest.permissions)
  if (manifest.permissions.length === 0) {
    issues.push({ path: "/museterm/permissions", message: "至少声明一项权限" })
  }
  if (!granted.has("palette")) {
    issues.push({
      path: "/museterm/permissions",
      message: "声明了命令就必须有 palette 权限",
    })
  }
  if (manifest.ai !== undefined && !granted.has("ai.suggest")) {
    issues.push({
      path: "/museterm/ai",
      message: "声明了 AI 候选就必须有 ai.suggest 权限",
    })
  }
  if (manifest.recording !== undefined && !granted.has("recording.observe")) {
    issues.push({
      path: "/museterm/recording",
      message: "声明了录制观察就必须有 recording.observe 权限",
    })
  }
  return issues
}

function duplicateIssues(manifest: PluginManifest): ManifestIssue[] {
  const issues: ManifestIssue[] = []
  issues.push(
    ...duplicates(
      manifest.commands.map((command) => command.id),
      "/museterm/commands",
      "命令 id 重复",
    ),
  )
  issues.push(
    ...duplicates(
      manifest.commands.map((command) => command.export),
      "/museterm/commands",
      "命令导出函数名重复",
    ),
  )
  const preferenceNames = manifest.preferences?.map((preference) => preference.name) ?? []
  issues.push(...duplicates(preferenceNames, "/museterm/preferences", "偏好名称重复"))
  manifest.preferences?.forEach((preference, index) => {
    if (preference.type !== "dropdown") return
    issues.push(
      ...duplicates(
        preference.data.map((choice) => choice.value),
        `/museterm/preferences/${index}/data`,
        "选项值重复",
      ),
    )
  })
  return issues
}

function dropdownDefaultIssues(manifest: PluginManifest): ManifestIssue[] {
  const issues: ManifestIssue[] = []
  manifest.preferences?.forEach((preference, index) => {
    if (preference.type !== "dropdown" || preference.default === undefined) return
    const values = new Set(preference.data.map((choice) => choice.value))
    if (!values.has(preference.default)) {
      issues.push({
        path: `/museterm/preferences/${index}/default`,
        message: "默认值必须是选项之一",
      })
    }
  })
  return issues
}

function engineIssues(manifest: PluginManifest, appVersion: string | undefined): ManifestIssue[] {
  if (appVersion === undefined) return []
  const range = manifest.engines.museterm
  const covered = versionRangeCovers(range, appVersion)
  if (covered === null) {
    const unreadable = parseVersion(appVersion) === null ? "应用版本号" : "版本范围"
    return [{
      path: "/museterm/engines/museterm",
      message: `${unreadable}无法识别，只接受 1.2.3、1.2.3-rc1、* 或 >=1.2.3`,
    }]
  }
  if (!covered) {
    return [{
      path: "/museterm/engines/museterm",
      message: `${range} 不覆盖应用版本 ${appVersion}`,
    }]
  }
  return []
}

function dependencyIssues(value: Record<string, unknown>): ManifestIssue[] {
  const issues: ManifestIssue[] = []
  for (const field of dependencyFields) {
    const dependencies = value[field]
    if (!isRecord(dependencies)) continue
    for (const [name, spec] of Object.entries(dependencies)) {
      if (typeof spec !== "string" || !remoteDependencyPattern.test(spec)) continue
      issues.push({
        path: `/${field}/${name}`,
        message: "依赖不能使用 file:、link: 或 git 地址",
      })
    }
  }
  return issues
}

function schemaIssues(errors: ErrorObject[] | null | undefined): ManifestIssue[] {
  return (errors ?? []).map((error) => ({
    path: error.instancePath === "" ? "/museterm" : `/museterm${error.instancePath}`,
    message: schemaMessage(error),
  }))
}

function schemaMessage(error: ErrorObject): string {
  const params = error.params
  switch (error.keyword) {
    case "required":
      return `缺少 ${stringParam(params, "missingProperty")}`
    case "additionalProperties":
      return `不能有额外字段 ${stringParam(params, "additionalProperty")}`
    case "enum":
    case "const":
      return "取值不在允许范围内"
    case "type":
      return "类型不对"
    case "minItems":
      return "不能为空"
    case "maxItems":
      return "数量超过上限"
    case "minimum":
    case "maximum":
      return "超出允许范围"
    case "minLength":
      return "不能为空"
    case "maxLength":
      return "超过长度上限"
    case "pattern":
      return "格式不对"
    case "uniqueItems":
      return "有重复项"
    default:
      return error.message ?? "不符合清单"
  }
}

function stringParam(params: unknown, key: string): string {
  if (typeof params !== "object" || params === null || !(key in params)) return ""
  const value = (params as Record<string, unknown>)[key]
  return typeof value === "string" ? value : ""
}

function duplicates(values: readonly string[], path: string, message: string): ManifestIssue[] {
  const seen = new Set<string>()
  const repeated = new Set<string>()
  for (const value of values) {
    if (seen.has(value)) repeated.add(value)
    seen.add(value)
  }
  return [...repeated].map((value) => ({ path, message: `${message}：${value}` }))
}

function hasLifecycleScripts(value: unknown): boolean {
  if (!isRecord(value)) return false
  return lifecycleScripts.some((name) => name in value)
}

/**
 * `>=1.2.3` uses SemVer ordering: a release is newer than a release candidate of
 * the same number, so `>=1.262.0` does not cover `1.262.0-rc2`.
 * Returns null when either side is not a supported version or range.
 */
export function versionRangeCovers(range: string, appVersion: string): boolean | null {
  const current = parseVersion(appVersion)
  if (current === null) return null
  if (range === "*") return true

  const bounded = range.startsWith(">=")
  const rawMinimum = bounded ? range.slice(2) : range
  if (rawMinimum.length === 0 || rawMinimum.includes(">") || rawMinimum.includes(" ")) return null
  const minimum = parseVersion(rawMinimum)
  if (minimum === null) return null
  const compared = compareVersions(current, minimum)
  return bounded ? compared >= 0 : compared === 0
}

function parseVersion(value: string): ParsedVersion | null {
  const match = versionPattern.exec(value)
  if (match === null) return null
  const major = Number(match[1])
  const minor = Number(match[2])
  const patch = Number(match[3])
  const rc = match[4] === undefined ? null : Number(match[4])
  if ([major, minor, patch, rc ?? 0].some((part) => !Number.isSafeInteger(part))) return null
  return { major, minor, patch, rc }
}

function compareVersions(left: ParsedVersion, right: ParsedVersion): number {
  const byNumber = left.major - right.major || left.minor - right.minor || left.patch - right.patch
  if (byNumber !== 0) return byNumber
  if (left.rc === right.rc) return 0
  if (left.rc === null) return 1
  if (right.rc === null) return -1
  return left.rc - right.rc
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}

function isNonEmptyString(value: unknown): value is string {
  return typeof value === "string" && value.trim().length > 0
}
