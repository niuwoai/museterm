import Foundation

enum RemoteShellIntegration {
    static let shellProbeCommand = "printf '\\033]777;MuseTerm;shell=%s\\a' \"$SHELL\""

    static func startupCommands(for profile: SSHConnectionProfile) -> [String] {
        guard profile.normalized.remoteShellIntegrationEnabled else { return [] }
        return [installCommand]
    }

    private static let installCommand = """
        _museterm_remote_hex() { printf '%s' "$1" | od -An -tx1 | tr -d ' \\n'; }
        _museterm_remote_emit_context() {
          local muse_cwd_hex muse_user_hex muse_uid muse_host_hex muse_shell_hex
          muse_cwd_hex=$(_museterm_remote_hex "${PWD:-}")
          muse_user_hex=$(_museterm_remote_hex "$(id -un 2>/dev/null)")
          muse_uid=$(id -u 2>/dev/null)
          muse_host_hex=$(_museterm_remote_hex "$(hostname 2>/dev/null)")
          muse_shell_hex=$(_museterm_remote_hex "${SHELL:-}")
          printf '\\033]777;MuseTerm;context=%s,%s,%s,%s,%s\\a' "$muse_cwd_hex" "$muse_user_hex" "$muse_uid" "$muse_host_hex" "$muse_shell_hex"
        }
        if [ -n "${ZSH_VERSION:-}" ]; then
          _museterm_remote_emit_start() { local muse_cmd_hex; muse_cmd_hex=$(printf '%s' "$1" | od -An -tx1 | tr -d ' \\n'); printf '\\033]777;MuseTerm;start=%s\\a' "$muse_cmd_hex"; }
          _museterm_remote_preexec() { _museterm_remote_emit_start "$1"; }
          _museterm_remote_precmd() { local muse_status=$?; printf '\\033]777;MuseTerm;end=%d\\a' "$muse_status"; _museterm_remote_emit_context; return "$muse_status"; }
          typeset -ga preexec_functions
          preexec_functions=(${preexec_functions:#_museterm_remote_preexec})
          preexec_functions=(_museterm_remote_preexec $preexec_functions)
          typeset -ga precmd_functions
          precmd_functions=(${precmd_functions:#_museterm_remote_precmd})
          precmd_functions=(_museterm_remote_precmd $precmd_functions)
        elif [ -n "${BASH_VERSION:-}" ]; then
          _museterm_remote_prompt_command() { local muse_status=$?; printf '\\033]777;MuseTerm;end=%d\\a' "$muse_status"; _museterm_remote_emit_context; return "$muse_status"; }
          case ";${PROMPT_COMMAND:-};" in
            *";_museterm_remote_prompt_command;"*) ;;
            *) PROMPT_COMMAND="_museterm_remote_prompt_command${PROMPT_COMMAND:+;$PROMPT_COMMAND}" ;;
          esac
        fi
        _museterm_remote_emit_context
        """
}
