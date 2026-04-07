# Bash completions for `clipboard`
#
# Install:
#   - System-wide: cp completions/clipboard.bash /etc/bash_completion.d/clipboard
#   - User:        source /path/to/completions/clipboard.bash  (add to ~/.bashrc)

_clipboard() {
    local cur prev words cword
    if declare -F _init_completion >/dev/null; then
        _init_completion || return
    else
        # Minimal fallback if bash-completion isn't installed
        COMPREPLY=()
        cur="${COMP_WORDS[COMP_CWORD]}"
        prev="${COMP_WORDS[COMP_CWORD-1]}"
        words=("${COMP_WORDS[@]}")
        cword=$COMP_CWORD
    fi

    local subcommands="list read write clear watch help"
    local global_flags="--json --help -h"

    # First positional: pick a subcommand
    if [[ $cword -eq 1 ]]; then
        COMPREPLY=( $(compgen -W "$subcommands $global_flags" -- "$cur") )
        return
    fi

    # Find which subcommand the user picked (skipping global flags)
    local subcmd="" i
    for (( i=1; i < cword; i++ )); do
        case "${words[i]}" in
            --json|--help|-h) ;;
            *) subcmd="${words[i]}"; break ;;
        esac
    done

    # Handle flags that take an argument
    case "$prev" in
        --out)
            # File path completion for `read --out`
            if declare -F _filedir >/dev/null; then
                _filedir
            else
                COMPREPLY=( $(compgen -f -- "$cur") )
            fi
            return
            ;;
        --data|--interval)
            return
            ;;
    esac

    case "$subcmd" in
        read|write)
            # Complete the format argument from `clipboard list`
            local prev_non_flag_count=0 j
            for (( j=1; j < cword; j++ )); do
                case "${words[j]}" in
                    --json|--help|-h|--out|--data|--interval) ;;
                    *) ((prev_non_flag_count++)) ;;
                esac
                # Skip the value of flags that take an argument
                case "${words[j]}" in
                    --out|--data|--interval) ((j++)) ;;
                esac
            done

            # prev_non_flag_count includes the subcommand itself; we want the
            # next positional, so complete formats when count == 1 (just the subcmd)
            if [[ $prev_non_flag_count -eq 1 && "$cur" != -* ]]; then
                local formats
                formats=$(clipboard list 2>/dev/null)
                COMPREPLY=( $(compgen -W "$formats" -- "$cur") )
                return
            fi

            # Otherwise offer flags
            if [[ "$subcmd" == "read" ]]; then
                COMPREPLY=( $(compgen -W "--out $global_flags" -- "$cur") )
            else
                COMPREPLY=( $(compgen -W "--data $global_flags" -- "$cur") )
            fi
            ;;
        watch)
            COMPREPLY=( $(compgen -W "--interval $global_flags" -- "$cur") )
            ;;
        *)
            COMPREPLY=( $(compgen -W "$global_flags" -- "$cur") )
            ;;
    esac
}

complete -F _clipboard clipboard
