import Foundation

enum RemoteShellIntegration {
    static func startupCommands(for profile: SSHConnectionProfile) -> [String] {
        guard profile.normalized.remoteShellIntegrationEnabled else { return [] }
        return [installCommand]
    }

    private static let installCommand = """
        if [ -n "${ZSH_VERSION:-}" ]; then
          _museterm_remote_precmd() { local muse_status=$?; printf '\\033]777;MuseTerm;end=%d\\a' "$muse_status"; return "$muse_status"; }
          typeset -ga precmd_functions
          precmd_functions=(${precmd_functions:#_museterm_remote_precmd})
          precmd_functions=(_museterm_remote_precmd $precmd_functions)
        elif [ -n "${BASH_VERSION:-}" ]; then
          _museterm_remote_prompt_command() { local muse_status=$?; printf '\\033]777;MuseTerm;end=%d\\a' "$muse_status"; return "$muse_status"; }
          case ";${PROMPT_COMMAND:-};" in
            *";_museterm_remote_prompt_command;"*) ;;
            *) PROMPT_COMMAND="_museterm_remote_prompt_command${PROMPT_COMMAND:+;$PROMPT_COMMAND}" ;;
          esac
        fi
        """
}
