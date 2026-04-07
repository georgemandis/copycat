# Fish completions for `clipboard`
#
# Install: cp completions/clipboard.fish ~/.config/fish/completions/

# Subcommands (only when no subcommand has been given yet)
complete -c clipboard -f -n __fish_use_subcommand -a list  -d "List format names"
complete -c clipboard -f -n __fish_use_subcommand -a read  -d "Read format data"
complete -c clipboard -f -n __fish_use_subcommand -a write -d "Write format data"
complete -c clipboard -f -n __fish_use_subcommand -a clear -d "Clear the clipboard"
complete -c clipboard -f -n __fish_use_subcommand -a watch -d "Watch for clipboard changes"
complete -c clipboard -f -n __fish_use_subcommand -a help  -d "Show help"

# Dynamic format completion for `read` and `write`
complete -c clipboard -f \
    -n "__fish_seen_subcommand_from read write" \
    -a "(clipboard list 2>/dev/null)" \
    -d "Clipboard format"

# Global flags
complete -c clipboard -l json     -d "Output as JSON"
complete -c clipboard -l help -s h -d "Show help"

# Subcommand-specific flags
complete -c clipboard -n "__fish_seen_subcommand_from read"  -l out      -r -F -d "Write output to file"
complete -c clipboard -n "__fish_seen_subcommand_from write" -l data     -r    -d "Inline data to write"
complete -c clipboard -n "__fish_seen_subcommand_from watch" -l interval -r    -d "Poll interval (ms)"
