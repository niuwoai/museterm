struct CommandDiagnosticAction: Codable, Equatable {
    let id: CommandDiagnosticActionID
    let sourceCategory: CommandDiagnosticCategory
    let confidence: CommandDiagnosticConfidence
    let priorityScore: Int
    let priorityFactors: [CommandDiagnosticPriorityFactor]
    let evidenceAnchors: [CommandDiagnosticEvidenceAnchor]
    let actionScope: CommandDiagnosticActionScope
    let expectedResultKind: CommandDiagnosticActionResultKind
    let expectedResultFields: [CommandDiagnosticActionResultField]
    let expectedResultSignals: [CommandDiagnosticActionResultSignal]
    let resultParsingHints: [CommandDiagnosticActionResultParsingHint]
    let resultInterpretationHints: [CommandDiagnosticActionResultInterpretationHint]
    let resultDecisionHints: [CommandDiagnosticActionResultDecisionHint]
    let resultCaveats: [CommandDiagnosticActionResultCaveat]
    let sensitiveResultFields: [CommandDiagnosticActionResultField]
    let resultRedactionHints: [CommandDiagnosticActionRedactionHint]
    let resultRefreshTriggers: [CommandDiagnosticActionRefreshTrigger]
    let resultPrivacyLevel: CommandDiagnosticActionPrivacyLevel
    let resultSharingPolicy: CommandDiagnosticActionSharingPolicy
    let resultRetentionPolicy: CommandDiagnosticActionRetentionPolicy
    let title: String
    let rationale: String
    let command: String
    let expectedSignals: [String]
    let preflightChecks: [String]
    let automationGuardrails: [String]
    let userDecisionPoints: [String]
    let completionCriteria: [String]
    let fallbackNextSteps: [String]
    let safety: CommandDiagnosticActionSafety
    let executionMode: CommandDiagnosticActionExecutionMode
    let executionTarget: CommandDiagnosticActionExecutionTarget
    let resultValidityScope: CommandDiagnosticActionResultValidityScope
    let resultFreshnessPolicy: CommandDiagnosticActionResultFreshnessPolicy
    let resultReuseKeyFields: [CommandDiagnosticActionResultReuseKeyField]
    let resultReusePolicy: CommandDiagnosticActionResultReusePolicy
    let resultReuseValidationChecks: [CommandDiagnosticActionResultReuseValidationCheck]
    let retryCondition: CommandDiagnosticActionRetryCondition
    let requiresConfirmation: Bool

    nonisolated init(
        id: CommandDiagnosticActionID,
        sourceCategory: CommandDiagnosticCategory,
        confidence: CommandDiagnosticConfidence,
        priorityScore: Int,
        priorityFactors: [CommandDiagnosticPriorityFactor],
        evidenceAnchors: [CommandDiagnosticEvidenceAnchor],
        actionScope: CommandDiagnosticActionScope,
        expectedResultKind: CommandDiagnosticActionResultKind,
        expectedResultFields: [CommandDiagnosticActionResultField],
        expectedResultSignals: [CommandDiagnosticActionResultSignal],
        resultParsingHints: [CommandDiagnosticActionResultParsingHint],
        resultInterpretationHints: [CommandDiagnosticActionResultInterpretationHint],
        resultDecisionHints: [CommandDiagnosticActionResultDecisionHint],
        resultCaveats: [CommandDiagnosticActionResultCaveat],
        sensitiveResultFields: [CommandDiagnosticActionResultField],
        resultRedactionHints: [CommandDiagnosticActionRedactionHint],
        resultRefreshTriggers: [CommandDiagnosticActionRefreshTrigger],
        resultPrivacyLevel: CommandDiagnosticActionPrivacyLevel,
        resultSharingPolicy: CommandDiagnosticActionSharingPolicy,
        resultRetentionPolicy: CommandDiagnosticActionRetentionPolicy,
        title: String,
        rationale: String,
        command: String,
        expectedSignals: [String],
        preflightChecks: [String],
        automationGuardrails: [String],
        userDecisionPoints: [String],
        completionCriteria: [String],
        fallbackNextSteps: [String],
        safety: CommandDiagnosticActionSafety,
        executionMode: CommandDiagnosticActionExecutionMode = .stageOnly,
        executionTarget: CommandDiagnosticActionExecutionTarget,
        resultValidityScope: CommandDiagnosticActionResultValidityScope,
        resultFreshnessPolicy: CommandDiagnosticActionResultFreshnessPolicy,
        resultReuseKeyFields: [CommandDiagnosticActionResultReuseKeyField],
        resultReusePolicy: CommandDiagnosticActionResultReusePolicy,
        resultReuseValidationChecks: [CommandDiagnosticActionResultReuseValidationCheck],
        retryCondition: CommandDiagnosticActionRetryCondition,
        requiresConfirmation: Bool = true
    ) {
        self.id = id
        self.sourceCategory = sourceCategory
        self.confidence = confidence
        self.priorityScore = priorityScore
        self.priorityFactors = priorityFactors
        self.evidenceAnchors = evidenceAnchors
        self.actionScope = actionScope
        self.expectedResultKind = expectedResultKind
        self.expectedResultFields = expectedResultFields
        self.expectedResultSignals = expectedResultSignals
        self.resultParsingHints = resultParsingHints
        self.resultInterpretationHints = resultInterpretationHints
        self.resultDecisionHints = resultDecisionHints
        self.resultCaveats = resultCaveats
        self.sensitiveResultFields = sensitiveResultFields
        self.resultRedactionHints = resultRedactionHints
        self.resultRefreshTriggers = resultRefreshTriggers
        self.resultPrivacyLevel = resultPrivacyLevel
        self.resultSharingPolicy = resultSharingPolicy
        self.resultRetentionPolicy = resultRetentionPolicy
        self.title = title
        self.rationale = rationale
        self.command = command
        self.expectedSignals = expectedSignals
        self.preflightChecks = preflightChecks
        self.automationGuardrails = automationGuardrails
        self.userDecisionPoints = userDecisionPoints
        self.completionCriteria = completionCriteria
        self.fallbackNextSteps = fallbackNextSteps
        self.safety = safety
        self.executionMode = executionMode
        self.executionTarget = executionTarget
        self.resultValidityScope = resultValidityScope
        self.resultFreshnessPolicy = resultFreshnessPolicy
        self.resultReuseKeyFields = resultReuseKeyFields
        self.resultReusePolicy = resultReusePolicy
        self.resultReuseValidationChecks = resultReuseValidationChecks
        self.retryCondition = retryCondition
        self.requiresConfirmation = requiresConfirmation
    }
}

enum CommandDiagnosticActionID: String, Codable, Equatable {
    case listListeningPorts = "list_listening_ports"
    case inspectPermissions = "inspect_permissions"
    case inspectPath = "inspect_path"
    case inspectDirectory = "inspect_directory"
    case inspectGitState = "inspect_git_state"
    case inspectRepeatContext = "inspect_repeat_context"
    case inspectLocalContext = "inspect_local_context"
}

enum CommandDiagnosticActionSafety: String, Codable, Equatable {
    case readOnly = "read_only"
}

enum CommandDiagnosticActionExecutionMode: String, Codable, Equatable {
    case stageOnly = "stage_only"
}

enum CommandDiagnosticEvidenceAnchor: String, Codable, Equatable {
    case latestFailedCommandID = "latest_failed_command_id"
    case latestFailedCommand = "latest_failed_command"
    case recentFailureCommandID = "recent_failure_command_id"
    case recentFailureWorkingDirectory = "recent_failure_working_directory"
    case recentFailureDiagnostic = "recent_failure_diagnostic"
    case recentFailureFingerprint = "recent_failure_fingerprint"
    case recentFailureOutputTailLine = "recent_failure_output_tail_line"
    case repeatedFailureDiagnostic = "repeated_failure_diagnostic"
    case retryPauseDecisionAnchorCommandID = "retry_pause_decision_anchor_command_id"
    case diagnosticCategoryEvidence = "diagnostic_category_evidence"
}

enum CommandDiagnosticActionScope: String, Codable, Equatable {
    case terminalSession = "terminal_session"
    case localNetwork = "local_network"
    case permissionBoundary = "permission_boundary"
    case shellEnvironment = "shell_environment"
    case workingDirectory = "working_directory"
    case gitRepository = "git_repository"
    case repeatedFailureContext = "repeated_failure_context"
}

enum CommandDiagnosticActionResultKind: String, Codable, Equatable {
    case listeningPorts = "listening_ports"
    case identityAndPermissions = "identity_and_permissions"
    case shellPath = "shell_path"
    case directoryListing = "directory_listing"
    case gitStatus = "git_status"
    case contextSnapshot = "context_snapshot"
}

enum CommandDiagnosticActionResultField: String, Codable, Equatable {
    case localPort = "local_port"
    case processID = "process_id"
    case processName = "process_name"
    case listenAddress = "listen_address"
    case workingDirectory = "working_directory"
    case currentUser = "current_user"
    case directoryPermissions = "directory_permissions"
    case pathEntries = "path_entries"
    case visibleEntries = "visible_entries"
    case fileMetadata = "file_metadata"
    case gitBranch = "git_branch"
    case gitUpstream = "git_upstream"
    case gitDirtyState = "git_dirty_state"
}

enum CommandDiagnosticActionResultSignal: String, Codable, Equatable {
    case targetPortVisible = "target_port_visible"
    case ownerProcessVisible = "owner_process_visible"
    case currentUserVisible = "current_user_visible"
    case permissionBoundaryVisible = "permission_boundary_visible"
    case pathEntriesVisible = "path_entries_visible"
    case workingDirectoryVisible = "working_directory_visible"
    case directoryEntriesVisible = "directory_entries_visible"
    case gitBranchVisible = "git_branch_visible"
    case gitDirtyStateVisible = "git_dirty_state_visible"
    case gitStateVisible = "git_state_visible"
}

enum CommandDiagnosticActionResultParsingHint: String, Codable, Equatable {
    case lineOrientedText = "line_oriented_text"
    case whitespaceSeparatedColumns = "whitespace_separated_columns"
    case pathList = "path_list"
    case commandSequenceOutput = "command_sequence_output"
    case directoryListingOutput = "directory_listing_output"
    case gitStatusPorcelain = "git_status_porcelain"
    case optionalGitStatusOutput = "optional_git_status_output"
}

enum CommandDiagnosticActionResultInterpretationHint: String, Codable, Equatable {
    case emptyOutputMeansNoLocalListener = "empty_output_means_no_local_listener"
    case rowsIdentifyOwners = "rows_identify_owners"
    case compareUserAndPermissions = "compare_user_and_permissions"
    case mismatchExplainsPermissionFailure = "mismatch_explains_permission_failure"
    case pathEntryPresenceMatters = "path_entry_presence_matters"
    case missingPathEntryExplainsCommandFailure = "missing_path_entry_explains_command_failure"
    case missingEntryConfirmsPathIssue = "missing_entry_confirms_path_issue"
    case caseMismatchMayMatter = "case_mismatch_may_matter"
    case dirtyStateRequiresUserDecision = "dirty_state_requires_user_decision"
    case upstreamRelationMayExplainFailure = "upstream_relation_may_explain_failure"
    case gitOutputOptional = "git_output_optional"
    case compareAgainstFirstFailure = "compare_against_first_failure"
    case contextSnapshotMayBePartial = "context_snapshot_may_be_partial"
}

enum CommandDiagnosticActionResultDecisionHint: String, Codable, Equatable {
    case portOwnerRequiresUserDecision = "port_owner_requires_user_decision"
    case noLocalListenerSuggestsScopeCheck = "no_local_listener_suggests_scope_check"
    case permissionMismatchNeedsExplicitElevation = "permission_mismatch_needs_explicit_elevation"
    case ownershipChangeRequiresApproval = "ownership_change_requires_approval"
    case missingPathEntrySuggestsActivationOrInstall = "missing_path_entry_suggests_activation_or_install"
    case installationRequiresUserChoice = "installation_requires_user_choice"
    case missingEntryRequiresRestoreGenerateOrReconfigure = "missing_entry_requires_restore_generate_or_reconfigure"
    case generatedPrerequisiteMayBeNeeded = "generated_prerequisite_may_be_needed"
    case dirtyGitStateNeedsResolutionChoice = "dirty_git_state_needs_resolution_choice"
    case cleanGitStateSuggestsRemoteOrAuthCheck = "clean_git_state_suggests_remote_or_auth_check"
    case unchangedContextDiscouragesRetry = "unchanged_context_discourages_retry"
    case changedContextNeedsComparison = "changed_context_needs_comparison"
    case capturedContextShouldRecategorize = "captured_context_should_recategorize"
    case genericFailureNeedsTargetedProbe = "generic_failure_needs_targeted_probe"
}

enum CommandDiagnosticActionResultCaveat: String, Codable, Equatable {
    case localNetworkNamespaceOnly = "local_network_namespace_only"
    case containerOrRemoteListenersMayBeMissing = "container_or_remote_listeners_may_be_missing"
    case permissionsArePathScoped = "permissions_are_path_scoped"
    case sudoOrRemoteContextMayDiffer = "sudo_or_remote_context_may_differ"
    case pathIsShellSpecific = "path_is_shell_specific"
    case toolMayExistOutsidePath = "tool_may_exist_outside_path"
    case directorySnapshotMayBecomeStale = "directory_snapshot_may_become_stale"
    case generatedFilesMayAppearAfterSetup = "generated_files_may_appear_after_setup"
    case gitStatusRequiresRepository = "git_status_requires_repository"
    case cleanTreeDoesNotRuleOutRemoteFailure = "clean_tree_does_not_rule_out_remote_failure"
    case contextSnapshotIsPartial = "context_snapshot_is_partial"
    case firstFailureOutputMayStillBeNeeded = "first_failure_output_may_still_be_needed"
    case genericFailureStillNeedsSpecificEvidence = "generic_failure_still_needs_specific_evidence"
}

enum CommandDiagnosticActionRedactionHint: String, Codable, Equatable {
    case processIdentity = "process_identity"
    case networkAddress = "network_address"
    case workingDirectory = "working_directory"
    case userIdentity = "user_identity"
    case permissionMetadata = "permission_metadata"
    case shellPathEntries = "shell_path_entries"
    case directoryEntries = "directory_entries"
    case fileMetadata = "file_metadata"
    case gitBranch = "git_branch"
    case gitUpstream = "git_upstream"
}

enum CommandDiagnosticActionRefreshTrigger: String, Codable, Equatable {
    case processStateChanged = "process_state_changed"
    case networkListenersChanged = "network_listeners_changed"
    case workingDirectoryChanged = "working_directory_changed"
    case userContextChanged = "user_context_changed"
    case permissionsChanged = "permissions_changed"
    case shellEnvironmentChanged = "shell_environment_changed"
    case filesystemChanged = "filesystem_changed"
    case gitStateChanged = "git_state_changed"
    case failureContextChanged = "failure_context_changed"
}

enum CommandDiagnosticActionPrivacyLevel: String, Codable, Equatable {
    case low
    case contextual
    case sensitive
}

enum CommandDiagnosticActionSharingPolicy: String, Codable, Equatable {
    case shareDirectly = "share_directly"
    case redactBeforeSharing = "redact_before_sharing"
    case localOnly = "local_only"
}

enum CommandDiagnosticActionRetentionPolicy: String, Codable, Equatable {
    case persistFull = "persist_full"
    case persistRedactedSummary = "persist_redacted_summary"
    case localSessionOnly = "local_session_only"
}

enum CommandDiagnosticActionExecutionTarget: String, Codable, Equatable {
    case currentTerminalSession = "current_terminal_session"
    case currentTerminalNetworkNamespace = "current_terminal_network_namespace"
    case currentWorkingDirectory = "current_working_directory"
    case currentShellEnvironment = "current_shell_environment"
    case currentGitRepository = "current_git_repository"
}

enum CommandDiagnosticActionResultValidityScope: String, Codable, Equatable {
    case currentTerminalSession = "current_terminal_session"
    case currentTerminalNetworkNamespace = "current_terminal_network_namespace"
    case currentWorkingDirectory = "current_working_directory"
    case currentShellEnvironment = "current_shell_environment"
    case currentGitRepository = "current_git_repository"
}

enum CommandDiagnosticActionResultFreshnessPolicy: String, Codable, Equatable {
    case liveSnapshot = "live_snapshot"
    case contextBound = "context_bound"
    case failureAttemptBound = "failure_attempt_bound"
}

enum CommandDiagnosticActionResultReuseKeyField: String, Codable, Equatable {
    case terminalSession = "terminal_session"
    case terminalNetworkNamespace = "terminal_network_namespace"
    case workingDirectory = "working_directory"
    case shellEnvironment = "shell_environment"
    case userIdentity = "user_identity"
    case permissionMetadata = "permission_metadata"
    case filesystemState = "filesystem_state"
    case networkListeners = "network_listeners"
    case gitRepository = "git_repository"
    case gitBranch = "git_branch"
    case gitWorkingTreeState = "git_working_tree_state"
    case failureFingerprint = "failure_fingerprint"
}

enum CommandDiagnosticActionResultReusePolicy: String, Codable, Equatable {
    case refreshBeforeUse = "refresh_before_use"
    case reuseWhenKeysMatch = "reuse_when_keys_match"
    case doNotReuseAcrossAttempts = "do_not_reuse_across_attempts"
}

enum CommandDiagnosticActionResultReuseValidationCheck: String, Codable, Equatable {
    case refreshDynamicSnapshot = "refresh_dynamic_snapshot"
    case matchReuseKeys = "match_reuse_keys"
    case matchWorkingDirectory = "match_working_directory"
    case matchShellEnvironment = "match_shell_environment"
    case matchUserIdentity = "match_user_identity"
    case matchNetworkNamespace = "match_network_namespace"
    case matchGitRepository = "match_git_repository"
    case matchGitState = "match_git_state"
    case matchFailureFingerprint = "match_failure_fingerprint"
    case matchObservedSignal = "match_observed_signal"
    case doNotCrossAttemptBoundary = "do_not_cross_attempt_boundary"
}

enum CommandDiagnosticActionRetryCondition: String, Codable, Equatable {
    case portConflictResolvedOrOwnerKnown = "port_conflict_resolved_or_owner_known"
    case permissionsVerified = "permissions_verified"
    case commandAvailableOnPath = "command_available_on_path"
    case fileOrDirectoryVerified = "file_or_directory_verified"
    case gitStateReviewed = "git_state_reviewed"
    case contextChangedOrFirstFailureInspected = "context_changed_or_first_failure_inspected"
    case localContextCaptured = "local_context_captured"
}
