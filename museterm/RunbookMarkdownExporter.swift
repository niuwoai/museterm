import Foundation

enum RunbookMarkdownExporter {
    static func markdown(
        tab: TerminalSession,
        blocks: [TerminalCommandBlock],
        query: String,
        failuresOnly: Bool,
        note: String,
        redactSensitiveData: Bool,
        includeReplayScript: Bool,
        parameterizeReplayScript: Bool,
        confirmReplaySteps: Bool,
        variableOverrides: RunbookReplayVariableOverrides
    ) -> String {
        guard !blocks.isEmpty else { return "" }

        var lines: [String] = []
        lines.append("# \(L10n.string("runbook.title"))")
        lines.append("")
        lines.append("- \(L10n.string("runbook.tab")): \(escapeInline(tab.tabTitle))")
        if let subtitle = tab.tabSubtitle, !subtitle.isEmpty {
            lines.append("- \(L10n.string("runbook.target")): \(escapeInline(subtitle))")
        }
        lines.append("- \(L10n.string("runbook.environment")): \(tab.environment.name)")
        lines.append("- \(L10n.string("runbook.generated_at")): \(timestamp(Date()))")
        lines.append("- \(L10n.string("runbook.command_count")): \(blocks.count)")

        let cleanedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanedQuery.isEmpty {
            lines.append("- \(L10n.string("runbook.filter_query")): `\(escapeInline(cleanedQuery))`")
        }
        if failuresOnly {
            lines.append("- \(L10n.string("runbook.filter_failures")): \(L10n.string("runbook.yes"))")
        }
        let sensitiveOutputCount = blocks.filter { RunbookSensitiveRedactor.containsSensitiveData($0.outputTail) }.count
        if sensitiveOutputCount > 0 {
            lines.append("- \(L10n.string("runbook.sensitive_outputs")): \(sensitiveOutputCount)")
            lines.append(
                "- \(L10n.string("runbook.redaction")): \(redactSensitiveData ? L10n.string("runbook.redaction_on") : L10n.string("runbook.redaction_off"))"
            )
        }
        let diagnostics = CommandBlockDiagnostics(blocks: blocks, redactSensitiveData: redactSensitiveData)
        appendDiagnostics(diagnostics, to: &lines)

        let cleanedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanedNote.isEmpty {
            lines.append("")
            lines.append("## \(L10n.string("runbook.notes"))")
            lines.append("")
            lines.append(redact(cleanedNote, enabled: redactSensitiveData))
        }

        if includeReplayScript {
            appendReplayScript(
                blocks: blocks,
                redactSensitiveData: redactSensitiveData,
                parameterizeReplayScript: parameterizeReplayScript,
                confirmReplaySteps: confirmReplaySteps,
                variableOverrides: variableOverrides,
                to: &lines
            )
        }

        for (index, block) in blocks.enumerated() {
            appendBlock(
                block,
                index: index,
                redactSensitiveData: redactSensitiveData,
                to: &lines
            )
        }

        return lines.joined(separator: "\n") + "\n"
    }

    static func replayScript(
        blocks: [TerminalCommandBlock],
        redactSensitiveData: Bool,
        parameterizePaths: Bool,
        confirmEachStep: Bool,
        variableOverrides: RunbookReplayVariableOverrides
    ) -> String {
        let parameterizer = RunbookReplayParameterizer(
            blocks: blocks,
            enabled: parameterizePaths,
            overrides: variableOverrides
        )
        let commands = blocks
            .map { parameterizer.parameterize(redact($0.command.trimmingCharacters(in: .whitespacesAndNewlines), enabled: redactSensitiveData)) }
            .filter { !$0.isEmpty }
        guard !commands.isEmpty else { return "" }
        var lines = ["set -euo pipefail"]
        lines.append(contentsOf: parameterizer.variableLines)

        if confirmEachStep {
            lines.append("")
            lines.append("run_step() {")
            lines.append("  local command=\"$1\"")
            lines.append("  printf '\\n$ %s\\n' \"$command\"")
            lines.append("  read -r -p \"Run this command? [y/N] \" reply")
            lines.append("  case \"$reply\" in")
            lines.append("    [yY]|[yY][eE][sS]) eval \"$command\" ;;")
            lines.append("    *) printf 'Skipped.\\n' ;;")
            lines.append("  esac")
            lines.append("}")
            lines.append("")
            lines.append(contentsOf: commands.map { "run_step \(shellSingleQuoted($0))" })
        } else {
            lines.append(contentsOf: commands)
        }

        return lines.joined(separator: "\n") + "\n"
    }

    static func defaultFilename(for tab: TerminalSession) -> String {
        let cleanedTitle = tab.tabTitle
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9._-]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        let base = cleanedTitle.isEmpty ? "museterm-runbook" : "museterm-\(cleanedTitle)"
        return "\(base)-\(filenameTimestamp()).md"
    }

    private static func appendDiagnostics(_ diagnostics: CommandBlockDiagnostics, to lines: inout [String]) {
        if diagnostics.failedCommandCount > 0 {
            lines.append("- \(L10n.string("runbook.failed_commands")): \(diagnostics.failedCommandCount)")
        }
        if diagnostics.diagnosticPriorityScore > 0 {
            lines.append("- \(L10n.string("runbook.diagnostic_priority_score")): \(diagnostics.diagnosticPriorityScore)")
        }
        if !diagnostics.diagnosticPriorityFactors.isEmpty {
            let factors = diagnostics.diagnosticPriorityFactors.map(\.rawValue).joined(separator: ", ")
            lines.append("- \(L10n.string("runbook.diagnostic_priority_factors")): \(factors)")
        }
        if diagnostics.diagnosticSeverity != .none {
            lines.append("- \(L10n.string("runbook.diagnostic_severity")): \(diagnostics.diagnosticSeverity.rawValue)")
        }
        if diagnostics.diagnosticCategory != .none {
            lines.append("- \(L10n.string("runbook.diagnostic_category")): \(diagnostics.diagnosticCategory.rawValue)")
        }
        if let diagnosticCategoryEvidence = diagnostics.diagnosticCategoryEvidence {
            lines.append("- \(L10n.string("runbook.diagnostic_category_evidence")): `\(escapeInline(diagnosticCategoryEvidence))`")
        }
        if diagnostics.diagnosticCategoryConfidence != .none {
            lines.append(
                "- \(L10n.string("runbook.diagnostic_category_confidence")): \(diagnostics.diagnosticCategoryConfidence.rawValue)"
            )
        }
        if let latestFailedCommandID = diagnostics.latestFailedCommandID {
            lines.append("- \(L10n.string("runbook.latest_failed_command_id")): `\(latestFailedCommandID.uuidString)`")
        }
        if let latestFailedCommand = diagnostics.latestFailedCommand {
            lines.append("- \(L10n.string("runbook.latest_failed_command")): `\(escapeInline(latestFailedCommand))`")
        }
        if let latestFailedWorkingDirectory = diagnostics.latestFailedWorkingDirectory {
            lines.append(
                "- \(L10n.string("runbook.latest_failed_working_directory")): `\(escapeInline(latestFailedWorkingDirectory))`"
            )
        }
        if let latestFailedExitCode = diagnostics.latestFailedExitCode {
            lines.append("- \(L10n.string("runbook.latest_failed_exit_code")): \(latestFailedExitCode)")
        }
        if let latestFailedDurationMilliseconds = diagnostics.latestFailedDurationMilliseconds {
            lines.append(
                "- \(L10n.string("runbook.latest_failed_duration")): \(latestFailedDurationMilliseconds) ms"
            )
        }
        if let latestFailedCommandStartSource = diagnostics.latestFailedCommandStartSource {
            lines.append(
                "- \(L10n.string("runbook.latest_failed_command_source")): \(latestFailedCommandStartSource.contextLabel)"
            )
        }
        if let latestFailedCompletionSource = diagnostics.latestFailedCompletionSource {
            lines.append(
                "- \(L10n.string("runbook.latest_failed_completion_source")): \(latestFailedCompletionSource.contextLabel)"
            )
        }
        if let recentFailureCommandID = diagnostics.recentFailureCommandID {
            lines.append("- \(L10n.string("runbook.recent_failure_command_id")): `\(recentFailureCommandID.uuidString)`")
        }
        if let recentFailureWorkingDirectory = diagnostics.recentFailureWorkingDirectory {
            lines.append(
                "- \(L10n.string("runbook.recent_failure_working_directory")): `\(escapeInline(recentFailureWorkingDirectory))`"
            )
        }
        if let recentFailureDiagnostic = diagnostics.recentFailureDiagnostic {
            lines.append("- \(L10n.string("runbook.latest_failure")): `\(escapeInline(recentFailureDiagnostic))`")
        }
        if let recentFailureFingerprint = diagnostics.recentFailureFingerprint {
            lines.append("- \(L10n.string("runbook.failure_fingerprint")): `\(escapeInline(recentFailureFingerprint))`")
        }
        if let recentFailureOutputTailLineNumber = diagnostics.recentFailureOutputTailLineNumber {
            lines.append(
                "- \(L10n.string("runbook.failure_output_tail_line")): \(recentFailureOutputTailLineNumber)"
            )
        }
        if let recentFailureOutputTailLineText = diagnostics.recentFailureOutputTailLineText {
            lines.append(
                "- \(L10n.string("runbook.failure_output_tail_text")): `\(escapeInline(recentFailureOutputTailLineText))`"
            )
        }
        appendRepeatedFailure(diagnostics.repeatedFailureDiagnostic, to: &lines)
        if let suggestedNextInspection = diagnostics.suggestedNextInspection {
            lines.append("- \(L10n.string("runbook.suggested_next_inspection")): \(escapeInline(suggestedNextInspection))")
        }
        if let suggestedNextCommand = diagnostics.suggestedNextCommand {
            lines.append("- \(L10n.string("runbook.suggested_next_command")): `\(escapeInline(suggestedNextCommand))`")
        }
        appendSuggestedAction(diagnostics.suggestedNextAction, to: &lines)
    }

    private static func appendRepeatedFailure(
        _ repeatedFailureDiagnostic: RepeatedFailureDiagnostic?,
        to lines: inout [String]
    ) {
        guard let repeatedFailureDiagnostic else { return }
        let repeatedText = L10n.format(
            "runbook.repeated_failure_value",
            repeatedFailureDiagnostic.count,
            "`\(escapeInline(repeatedFailureDiagnostic.diagnostic))`"
        )
        lines.append("- \(L10n.string("runbook.repeated_failure")): \(repeatedText)")
        lines.append(
            "- \(L10n.string("runbook.repeated_failure_match")): \(repeatedFailureDiagnostic.matchKind.rawValue)"
        )
        let commandIDs = repeatedFailureDiagnostic.commandIDs.map(\.uuidString).joined(separator: ", ")
        lines.append("- \(L10n.string("runbook.repeated_failure_command_ids")): `\(commandIDs)`")
        appendInlineCodeList(
            repeatedFailureDiagnostic.uniqueCommands,
            key: "runbook.repeated_failure_unique_commands",
            to: &lines
        )
        appendInlineCodeList(
            repeatedFailureDiagnostic.uniqueWorkingDirectories,
            key: "runbook.repeated_failure_unique_working_directories",
            to: &lines
        )
        lines.append(
            "- \(L10n.string("runbook.repeated_failure_context_changed")): \(repeatedFailureDiagnostic.contextChanged)"
        )
        lines.append(
            "- \(L10n.string("runbook.repeated_failure_context_stability")): \(repeatedFailureDiagnostic.contextStability.rawValue)"
        )
        appendRawValueList(
            repeatedFailureDiagnostic.contextChangeReasons,
            key: "runbook.repeated_failure_context_change_reasons",
            to: &lines
        )
        lines.append(
            "- \(L10n.string("runbook.repeated_failure_first_command_id")): `\(repeatedFailureDiagnostic.firstCommandID.uuidString)`"
        )
        lines.append(
            "- \(L10n.string("runbook.repeated_failure_latest_command_id")): `\(repeatedFailureDiagnostic.latestCommandID.uuidString)`"
        )
        lines.append(
            "- \(L10n.string("runbook.repeated_failure_first_command")): `\(escapeInline(repeatedFailureDiagnostic.firstCommand))`"
        )
        lines.append(
            "- \(L10n.string("runbook.repeated_failure_latest_command")): `\(escapeInline(repeatedFailureDiagnostic.latestCommand))`"
        )
        if let firstWorkingDirectory = repeatedFailureDiagnostic.firstWorkingDirectory {
            lines.append(
                "- \(L10n.string("runbook.repeated_failure_first_working_directory")): `\(escapeInline(firstWorkingDirectory))`"
            )
        }
        if let latestWorkingDirectory = repeatedFailureDiagnostic.latestWorkingDirectory {
            lines.append(
                "- \(L10n.string("runbook.repeated_failure_latest_working_directory")): `\(escapeInline(latestWorkingDirectory))`"
            )
        }
        if let firstOutputTailLineNumber = repeatedFailureDiagnostic.firstOutputTailLineNumber {
            lines.append(
                "- \(L10n.string("runbook.repeated_failure_first_output_tail_line")): \(firstOutputTailLineNumber)"
            )
        }
        if let firstOutputTailLineText = repeatedFailureDiagnostic.firstOutputTailLineText {
            lines.append(
                "- \(L10n.string("runbook.repeated_failure_first_output_tail_text")): `\(escapeInline(firstOutputTailLineText))`"
            )
        }
        if let latestOutputTailLineNumber = repeatedFailureDiagnostic.latestOutputTailLineNumber {
            lines.append(
                "- \(L10n.string("runbook.repeated_failure_latest_output_tail_line")): \(latestOutputTailLineNumber)"
            )
        }
        if let latestOutputTailLineText = repeatedFailureDiagnostic.latestOutputTailLineText {
            lines.append(
                "- \(L10n.string("runbook.repeated_failure_latest_output_tail_text")): `\(escapeInline(latestOutputTailLineText))`"
            )
        }
        let windowText = L10n.format(
            "runbook.repeated_failure_window_value",
            timestamp(repeatedFailureDiagnostic.firstOccurredAt),
            timestamp(repeatedFailureDiagnostic.latestOccurredAt)
        )
        lines.append("- \(L10n.string("runbook.repeated_failure_window")): \(windowText)")
        lines.append(
            "- \(L10n.string("runbook.repeated_failure_duration")): \(repeatedFailureDiagnostic.durationMilliseconds) ms"
        )
        lines.append(
            "- \(L10n.string("runbook.repeated_failure_average_interval")): \(repeatedFailureDiagnostic.averageIntervalMilliseconds) ms"
        )
        lines.append(
            "- \(L10n.string("runbook.repeated_failure_latest_interval")): \(repeatedFailureDiagnostic.latestIntervalMilliseconds) ms"
        )
        lines.append(
            "- \(L10n.string("runbook.repeated_failure_latest_interval_trend")): \(repeatedFailureDiagnostic.latestIntervalTrend.rawValue)"
        )
        lines.append(
            "- \(L10n.string("runbook.repeated_failure_cadence")): \(repeatedFailureDiagnostic.cadence.rawValue)"
        )
        lines.append(
            "- \(L10n.string("runbook.repeated_failure_retry_pause_recommended")): \(repeatedFailureDiagnostic.retryPauseRecommended)"
        )
        lines.append(
            "- \(L10n.string("runbook.repeated_failure_retry_pause_severity")): \(repeatedFailureDiagnostic.retryPauseSeverity.rawValue)"
        )
        lines.append(
            "- \(L10n.string("runbook.repeated_failure_retry_pause_decision")): \(repeatedFailureDiagnostic.retryPauseDecision.rawValue)"
        )
        lines.append(
            "- \(L10n.string("runbook.repeated_failure_retry_pause_decision_confidence")): \(repeatedFailureDiagnostic.retryPauseDecisionConfidence.rawValue)"
        )
        if let retryPauseDecisionAnchorCommandID = repeatedFailureDiagnostic.retryPauseDecisionAnchorCommandID {
            lines.append(
                "- \(L10n.string("runbook.repeated_failure_retry_pause_decision_anchor_command_id")): `\(retryPauseDecisionAnchorCommandID.uuidString)`"
            )
        }
        appendRawValueList(
            repeatedFailureDiagnostic.retryPauseDecisionReasons,
            key: "runbook.repeated_failure_retry_pause_decision_reasons",
            to: &lines
        )
        appendRawValueList(
            repeatedFailureDiagnostic.retryPauseDecisionRefreshTriggers,
            key: "runbook.repeated_failure_retry_pause_decision_refresh_triggers",
            to: &lines
        )
        lines.append(
            "- \(L10n.string("runbook.repeated_failure_retry_pause_cooldown")): \(repeatedFailureDiagnostic.retryPauseCooldownMilliseconds) ms"
        )
        if let retryPauseUntil = repeatedFailureDiagnostic.retryPauseUntil {
            lines.append(
                "- \(L10n.string("runbook.repeated_failure_retry_pause_until")): \(timestamp(retryPauseUntil))"
            )
        }
        appendRawValueList(
            repeatedFailureDiagnostic.retryPauseReasons,
            key: "runbook.repeated_failure_retry_pause_reasons",
            to: &lines
        )
    }

    private static func appendSuggestedAction(_ action: CommandDiagnosticAction?, to lines: inout [String]) {
        guard let action else { return }
        lines.append("- \(L10n.string("runbook.suggested_next_action_id")): \(action.id.rawValue)")
        lines.append("- \(L10n.string("runbook.suggested_next_action_source_category")): \(action.sourceCategory.rawValue)")
        lines.append("- \(L10n.string("runbook.suggested_next_action_confidence")): \(action.confidence.rawValue)")
        lines.append("- \(L10n.string("runbook.suggested_next_action_priority_score")): \(action.priorityScore)")
        appendRawValueList(action.priorityFactors, key: "runbook.suggested_next_action_priority_factors", to: &lines)
        appendRawValueList(action.evidenceAnchors, key: "runbook.suggested_next_action_evidence_anchors", to: &lines)
        lines.append("- \(L10n.string("runbook.suggested_next_action_scope")): \(action.actionScope.rawValue)")
        lines.append("- \(L10n.string("runbook.suggested_next_action_expected_result_kind")): \(action.expectedResultKind.rawValue)")
        appendRawValueList(action.expectedResultFields, key: "runbook.suggested_next_action_expected_result_fields", to: &lines)
        appendRawValueList(action.expectedResultSignals, key: "runbook.suggested_next_action_expected_result_signals", to: &lines)
        appendRawValueList(action.resultParsingHints, key: "runbook.suggested_next_action_result_parsing_hints", to: &lines)
        appendRawValueList(action.resultInterpretationHints, key: "runbook.suggested_next_action_result_interpretation_hints", to: &lines)
        appendRawValueList(action.resultDecisionHints, key: "runbook.suggested_next_action_result_decision_hints", to: &lines)
        appendRawValueList(action.resultCaveats, key: "runbook.suggested_next_action_result_caveats", to: &lines)
        appendRawValueList(action.sensitiveResultFields, key: "runbook.suggested_next_action_sensitive_result_fields", to: &lines)
        appendRawValueList(action.resultRedactionHints, key: "runbook.suggested_next_action_result_redaction_hints", to: &lines)
        appendRawValueList(action.resultRefreshTriggers, key: "runbook.suggested_next_action_result_refresh_triggers", to: &lines)
        lines.append("- \(L10n.string("runbook.suggested_next_action_result_privacy_level")): \(action.resultPrivacyLevel.rawValue)")
        lines.append("- \(L10n.string("runbook.suggested_next_action_result_sharing_policy")): \(action.resultSharingPolicy.rawValue)")
        lines.append("- \(L10n.string("runbook.suggested_next_action_result_retention_policy")): \(action.resultRetentionPolicy.rawValue)")
        lines.append("- \(L10n.string("runbook.suggested_next_action")): \(escapeInline(action.title))")
        lines.append("- \(L10n.string("runbook.suggested_next_action_safety")): \(action.safety.rawValue)")
        lines.append("- \(L10n.string("runbook.suggested_next_action_execution_mode")): \(action.executionMode.rawValue)")
        lines.append("- \(L10n.string("runbook.suggested_next_action_execution_target")): \(action.executionTarget.rawValue)")
        lines.append("- \(L10n.string("runbook.suggested_next_action_result_validity_scope")): \(action.resultValidityScope.rawValue)")
        lines.append("- \(L10n.string("runbook.suggested_next_action_result_freshness_policy")): \(action.resultFreshnessPolicy.rawValue)")
        appendRawValueList(action.resultReuseKeyFields, key: "runbook.suggested_next_action_result_reuse_key_fields", to: &lines)
        lines.append("- \(L10n.string("runbook.suggested_next_action_result_reuse_policy")): \(action.resultReusePolicy.rawValue)")
        appendRawValueList(action.resultReuseValidationChecks, key: "runbook.suggested_next_action_result_reuse_validation_checks", to: &lines)
        lines.append("- \(L10n.string("runbook.suggested_next_action_retry_condition")): \(action.retryCondition.rawValue)")
        appendRawValueList(action.confirmationReasons, key: "runbook.suggested_next_action_confirmation_reasons", to: &lines)
        appendInlineCodeList(action.preflightChecks, key: "runbook.suggested_next_action_preflight_checks", to: &lines)
        appendInlineCodeList(action.automationGuardrails, key: "runbook.suggested_next_action_automation_guardrails", to: &lines)
        appendInlineCodeList(action.userDecisionPoints, key: "runbook.suggested_next_action_user_decision_points", to: &lines)
        appendInlineCodeList(action.completionCriteria, key: "runbook.suggested_next_action_completion_criteria", to: &lines)
        appendInlineCodeList(action.expectedSignals, key: "runbook.suggested_next_action_expected_signals", to: &lines)
        appendInlineCodeList(action.fallbackNextSteps, key: "runbook.suggested_next_action_fallback_steps", to: &lines)
        lines.append(
            "- \(L10n.string("runbook.suggested_next_action_confirmation")): \(action.requiresConfirmation ? L10n.string("runbook.yes") : L10n.string("runbook.no"))"
        )
        lines.append("- \(L10n.string("runbook.suggested_next_action_rationale")): \(escapeInline(action.rationale))")
    }

    private static func appendRawValueList<T: RawRepresentable>(
        _ values: [T],
        key: String,
        to lines: inout [String]
    ) where T.RawValue == String {
        guard !values.isEmpty else { return }
        lines.append("- \(L10n.string(key)): \(values.map(\.rawValue).joined(separator: ", "))")
    }

    private static func appendInlineCodeList(_ values: [String], key: String, to lines: inout [String]) {
        guard !values.isEmpty else { return }
        let text = values
            .map { "`\(escapeInline($0))`" }
            .joined(separator: ", ")
        lines.append("- \(L10n.string(key)): \(text)")
    }

    private static func appendReplayScript(
        blocks: [TerminalCommandBlock],
        redactSensitiveData: Bool,
        parameterizeReplayScript: Bool,
        confirmReplaySteps: Bool,
        variableOverrides: RunbookReplayVariableOverrides,
        to lines: inout [String]
    ) {
        lines.append("")
        lines.append("## \(L10n.string("runbook.replay_script"))")
        lines.append("")
        lines.append("- \(L10n.string("runbook.parameterized")): \(parameterizeReplayScript ? L10n.string("runbook.yes") : L10n.string("runbook.no"))")
        lines.append("- \(L10n.string("runbook.step_confirmation")): \(confirmReplaySteps ? L10n.string("runbook.yes") : L10n.string("runbook.no"))")
        if parameterizeReplayScript {
            let variables = RunbookReplayVariables(blocks: blocks, overrides: variableOverrides)
            lines.append("- RUNBOOK_HOME: `\(escapeInline(variables.homeLineDefault))`")
            if let workingDirectory = variables.workingDirectory {
                lines.append("- RUNBOOK_WORKDIR: `\(escapeInline(workingDirectory))`")
            }
        }
        lines.append("")
        lines.append(
            fenced(
                replayScript(
                    blocks: blocks,
                    redactSensitiveData: redactSensitiveData,
                    parameterizePaths: parameterizeReplayScript,
                    confirmEachStep: confirmReplaySteps,
                    variableOverrides: variableOverrides
                ),
                language: "bash"
            )
        )
    }

    private static func appendBlock(
        _ block: TerminalCommandBlock,
        index: Int,
        redactSensitiveData: Bool,
        to lines: inout [String]
    ) {
        lines.append("")
        lines.append("## \(index + 1). \(escapeHeading(block.command))")
        lines.append("")
        if let workingDirectory = block.workingDirectory, !workingDirectory.isEmpty {
            lines.append("- \(L10n.string("runbook.directory")): `\(escapeInline(workingDirectory))`")
        }
        lines.append("- \(L10n.string("runbook.started")): \(timestamp(block.startedAt))")
        if let endedAt = block.endedAt {
            lines.append("- \(L10n.string("runbook.ended")): \(timestamp(endedAt))")
        }
        if let durationMilliseconds = block.durationMilliseconds {
            lines.append("- \(L10n.string("runbook.duration")): \(durationMilliseconds) ms")
        }
        lines.append("- \(L10n.string("runbook.status")): \(statusText(for: block))")
        lines.append("- \(L10n.string("runbook.output_chars")): \(block.outputCharacterCount)")
        if let outputSummary = block.outputSummary, !outputSummary.isEmpty {
            lines.append("")
            lines.append("### \(L10n.string("runbook.output_summary"))")
            lines.append(fenced(outputSummaryText(outputSummary, redactSensitiveData: redactSensitiveData), language: "text"))
        }
        lines.append("")
        lines.append("### \(L10n.string("runbook.command"))")
        lines.append(fenced(redact(block.command, enabled: redactSensitiveData), language: "bash"))
        if !block.outputTail.isEmpty {
            lines.append("")
            lines.append("### \(L10n.string("runbook.output_tail"))")
            lines.append(fenced(redact(block.outputTail, enabled: redactSensitiveData), language: "text"))
        }
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func filenameTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private static func statusText(for block: TerminalCommandBlock) -> String {
        if block.endedAt == nil {
            return L10n.string("command_inspector.status.running")
        }
        if let exitCode = block.exitCode {
            return exitCode == 0
                ? L10n.string("command_inspector.status.ok")
                : L10n.format("command_inspector.status.exit", exitCode)
        }
        return L10n.string("command_inspector.status.done")
    }

    private static func outputSummaryText(_ summary: TerminalOutputSummary, redactSensitiveData: Bool) -> String {
        var lines: [String] = []
        if !summary.insightKinds.isEmpty {
            let labels = summary.insightKinds
                .map { L10n.string($0.labelKey) }
                .joined(separator: ", ")
            lines.append("\(L10n.string("runbook.summary_insights")): \(labels)")
        }
        appendSummaryLine(summary.errorLine, key: "runbook.summary_error", to: &lines, redactSensitiveData: redactSensitiveData)
        appendSummaryLine(summary.warningLine, key: "runbook.summary_warning", to: &lines, redactSensitiveData: redactSensitiveData)
        appendSummaryLine(summary.url, key: "runbook.summary_url", to: &lines, redactSensitiveData: redactSensitiveData)
        appendSummaryLine(summary.filePath, key: "runbook.summary_path", to: &lines, redactSensitiveData: redactSensitiveData)
        appendSummaryLine(summary.commitHash, key: "runbook.summary_commit", to: &lines, redactSensitiveData: redactSensitiveData)
        appendSummaryLine(summary.stackTraceLine, key: "runbook.summary_stack", to: &lines, redactSensitiveData: redactSensitiveData)
        return lines.joined(separator: "\n")
    }

    private static func appendSummaryLine(
        _ value: String?,
        key: String,
        to lines: inout [String],
        redactSensitiveData: Bool
    ) {
        guard let value, !value.isEmpty else { return }
        lines.append("\(L10n.string(key)): \(redact(value, enabled: redactSensitiveData))")
    }

    private static func fenced(_ text: String, language: String) -> String {
        let fence = text.contains("```") ? "````" : "```"
        return "\(fence)\(language)\n\(text)\n\(fence)"
    }

    private static func redact(_ text: String, enabled: Bool) -> String {
        enabled ? RunbookSensitiveRedactor.redact(text) : text
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func escapeInline(_ text: String) -> String {
        text.replacingOccurrences(of: "`", with: "\\`")
    }

    private static func escapeHeading(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "#", with: "\\#")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return escaped.isEmpty ? L10n.string("runbook.untitled_command") : escaped
    }
}

struct RunbookReplayVariableOverrides {
    var homePath: String
    var workingDirectory: String
}

struct RunbookReplayVariables {
    let homePath: String
    let workingDirectory: String?
    let homeUsesShellDefault: Bool

    init(blocks: [TerminalCommandBlock], overrides: RunbookReplayVariableOverrides) {
        let cleanedHome = overrides.homePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanedHome.isEmpty {
            homePath = FileManager.default.homeDirectoryForCurrentUser.path
            homeUsesShellDefault = true
        } else {
            homePath = (cleanedHome as NSString).expandingTildeInPath
            homeUsesShellDefault = false
        }

        let cleanedWorkingDirectory = overrides.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanedWorkingDirectory.isEmpty {
            workingDirectory = blocks
                .compactMap(\.workingDirectory)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty && $0.hasPrefix("/") }
        } else {
            workingDirectory = (cleanedWorkingDirectory as NSString).expandingTildeInPath
        }
    }

    var homeLineDefault: String {
        homeUsesShellDefault ? "$HOME" : homePath
    }
}

private struct RunbookReplayParameterizer {
    let enabled: Bool
    let variables: RunbookReplayVariables

    init(blocks: [TerminalCommandBlock], enabled: Bool, overrides: RunbookReplayVariableOverrides) {
        self.enabled = enabled
        variables = RunbookReplayVariables(blocks: blocks, overrides: overrides)
    }

    var variableLines: [String] {
        guard enabled else { return [] }

        var lines = [
            variables.homeUsesShellDefault
                ? "RUNBOOK_HOME=\"${RUNBOOK_HOME:-$HOME}\""
                : "RUNBOOK_HOME=${RUNBOOK_HOME:-\(shellSingleQuoted(variables.homePath))}"
        ]
        if let workingDirectory = variables.workingDirectory, !workingDirectory.isEmpty {
            lines.append("RUNBOOK_WORKDIR=${RUNBOOK_WORKDIR:-\(shellSingleQuoted(workingDirectory))}")
        }
        return lines
    }

    func parameterize(_ command: String) -> String {
        guard enabled else { return command }

        var result = command
        if let workingDirectory = variables.workingDirectory, !workingDirectory.isEmpty {
            result = result.replacingOccurrences(of: workingDirectory, with: "\"${RUNBOOK_WORKDIR}\"")
        }
        if !variables.homePath.isEmpty {
            result = result.replacingOccurrences(of: variables.homePath, with: "${RUNBOOK_HOME}")
        }
        return result
    }

    private func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
