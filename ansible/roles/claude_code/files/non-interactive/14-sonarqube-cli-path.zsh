if [[ -d "$HOME/.local/share/sonarqube-cli/bin" ]]; then
  case ":$PATH:" in
    *":$HOME/.local/share/sonarqube-cli/bin:"*) ;;
    *) export PATH="$HOME/.local/share/sonarqube-cli/bin:$PATH" ;;
  esac
fi
