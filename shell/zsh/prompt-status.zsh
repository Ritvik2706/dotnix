# Show failed exit codes and commands taking at least three seconds.
autoload -Uz add-zsh-hook
zmodload zsh/datetime

_dotnix_command_started() {
  _dotnix_command_start=$EPOCHSECONDS
}

_dotnix_command_finished() {
  local command_status=$?
  local -i elapsed=0
  [[ -n ${_dotnix_command_start-} ]] && elapsed=$(( EPOCHSECONDS - _dotnix_command_start ))
  unset _dotnix_command_start
  RPROMPT=''
  (( command_status )) && RPROMPT="%F{red}exit ${command_status}%f"
  if (( elapsed >= 3 )); then
    RPROMPT+="${RPROMPT:+ }%F{yellow}${elapsed}s%f"
  fi
  return 0
}

add-zsh-hook preexec _dotnix_command_started
# Capture the command status before other prompt hooks can change it.
add-zsh-hook -d precmd _dotnix_command_finished
precmd_functions=(_dotnix_command_finished ${precmd_functions[@]})
