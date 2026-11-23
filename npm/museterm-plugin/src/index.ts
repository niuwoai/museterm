export {
  checkPluginPackage,
  definePlugin,
  maximumCommandPriority,
  manifestSchemaVersion,
  pluginCommandID,
  pluginManifestSchema,
  pluginPermissions,
  versionRangeCovers,
} from "./manifest.js"

export type {
  CheckPluginPackageOptions,
  LocalizedText,
  ManifestIssue,
  PluginCommand,
  PluginManifest,
  PluginPackage,
  PluginPermission,
  PluginPreference,
  PluginPreferenceChoice,
} from "./manifest.js"
