# shellcheck shell=bash
# tui_target: "<goos>-<goarch>" of the dm-tui binary this device can run (fails when none).
# Shared by the dm launcher and the installers; Termux is android/arm64.

tui_target() {
  local os arch
  case $(uname -s) in
    Darwin) os=darwin ;;
    Linux)
      if [[ -n ${TERMUX_VERSION:-} || ${PREFIX:-} == */com.termux/* ]]; then
        os=android
      else
        os=linux
      fi
      ;;
    *) return 1 ;;
  esac
  case $(uname -m) in
    arm64 | aarch64) arch=arm64 ;;
    x86_64 | amd64) arch=amd64 ;;
    *) return 1 ;;
  esac
  printf '%s-%s\n' "$os" "$arch"
}
