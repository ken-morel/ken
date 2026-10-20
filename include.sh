#!/bin/zsh

alias -g '//'='| tee >(
    bat --paging=never --style=plain --language=md --color=always >/dev/tty;
    print -P "\n\e[1;36m[──────────]\e[0m\n" >/dev/tty
) |'

if [[ -n "$ZSH_VERSION" ]]; then
    _ken_execute_widget() {
        local input_text="$BUFFER"
        if [[ -z "${input_text//[[:space:]]/}" ]]; then
            printf '\a'
            return
        fi

        # 1. Starts with '#' -> Generate command
        if [[ "$input_text" =~ '^[[:space:]]*#' ]]; then
            local prompt="${input_text#*#}"
            zle -I
            local gen_cmd
            gen_cmd=$(ken cmd.qwen "GENERATE: $prompt" --no-mdc 2>/dev/null)
            if [[ -n "$gen_cmd" ]]; then
                BUFFER="$gen_cmd"
                CURSOR=${#BUFFER}
            else
                printf '\a'
            fi
            zle reset-prompt

        # 2. Contains '#' inside -> Modify base command with instruction
        elif [[ "$input_text" == *#* ]]; then
            local base_cmd="${input_text%%#*}"
            local instruction="${input_text#*#}"
            zle -I
            local gen_cmd
            gen_cmd=$(ken cmd.qwen "MODIFY: Base command: '${base_cmd%% }' | Instruction: '${instruction## }'" --no-mdc 2>/dev/null)
            if [[ -n "$gen_cmd" ]]; then
                BUFFER="$gen_cmd"
                CURSOR=${#BUFFER}
            else
                printf '\a'
            fi
            zle reset-prompt

        # 3. Ends with ';' -> Explain command detailly
        elif [[ "$input_text" =~ ';[[:space:]]*$' ]]; then
            zle -I
            ken cmd.qwen "EXPLAIN: $input_text"
            zle reset-prompt

        # 4. Neither format matches -> Bell / do nothing
        else
            printf '\a'
        fi
    }
    zle -N _ken_execute_widget
    bindkey '^[e' _ken_execute_widget
fi
