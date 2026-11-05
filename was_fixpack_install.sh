#!/usr/bin/env bash
# Copyright (c) 2026 Shivraj Mudaliyar. SPDX-License-Identifier: MIT. Provided "as is", without warranty (see LICENSE).
#
# was_fixpack_install.sh - apply a WebSphere Application Server traditional fix pack (8.5.5.x or 9.0.5.x)
# to one installation with IBM Installation Manager (imcl). Works out the version line from what is
# installed, so the same command is used on 8.5.5 and 9.0.5 hosts.
#
# Modes
#   (default)   precheck only - reports what would be installed, changes nothing
#   --apply     stop processes (if --stop), back up (if --backup-dir), install, verify, clear OSGi cache,
#               restart what was running (if --restart)
#   --rollback  imcl rollback of the WAS (and Java) package to the previous level
#
# Exit codes: 0 ok / nothing to do, 1 usage, 2 precheck failed, 3 install or rollback failed,
#             4 post-install verification failed, 5 another run holds the lock
#
# Run as the user that owns the WAS installation (the same user that installed it with IM).
set -u
umask 027
PATH=/usr/bin:/bin:/usr/sbin:/sbin:$PATH
export LC_ALL=C

VERSION=1.0.0
ME=$(basename "$0")

usage() {
  cat <<EOF
Usage: $ME --was-home DIR --repo REPO[,REPO...] [options]

Required
  --was-home DIR        WAS install root, e.g. /opt/IBM/WebSphere/AppServer
  --repo LIST           comma-separated IM repositories: directories, .zip files or https:// URLs
                        (WAS fix pack repository plus the matching IBM Java SDK repository)
Options
  --target-level L      fix pack to install, e.g. 9.0.5.29 or 8.5.5.31 (default: highest in the repos)
  --imcl PATH           path to imcl (default: searched in the usual IM locations)
  --apply               make changes (without it the script only runs the prechecks)
  --rollback            roll back to the previous level instead of installing
  --stop                stop WAS processes running from --was-home before installing
  --restart             start again the processes that were running (needs --stop)
  --admin-user USER     administrative user for stop commands when admin security is on
  --password-file FILE  file holding that user's password (mode 600, owned by you)
  --backup-dir DIR      tar the install root and run backupConfig for each profile before installing
  --skip-java           do not update the Java SDK package even if one is installed
  --min-free-mb N       free space needed in the install filesystem (default 3072)
  --log-dir DIR         where logs go (default /var/tmp/was_fixpack)
  -h, --help            this help;  --version  print script version

Admin credentials can also come from soap.client.props in each profile, which keeps them off the command line.
EOF
}

# ------------------------------------------------------------------ helpers
ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { printf '%s [%s] %s\n' "$(ts)" "$1" "$2" | tee -a "$LOG" >&2; }
info() { log INFO "$*"; }
warn() { log WARN "$*"; WARNINGS=$((WARNINGS + 1)); }
die() { local rc=$1; shift; log ERROR "$*"; exit "$rc"; }
usage_err() { printf '%s: %s\n' "$ME" "$*" >&2; usage >&2; exit 1; }

# reject values containing control characters (newlines in paths break every later step)
clean() { case $1 in *[[:cntrl:]]*) return 1 ;; esac; return 0; }

# escape dots for grep -E (portable across bash versions, unlike ${v//./\\.})
re_esc() { printf '%s' "$1" | sed 's/\./\\./g'; }

# version compare on dotted/underscored numbers: ver_ge A B  -> true when A >= B
ver_ge() {
  awk -v a="$1" -v b="$2" 'BEGIN{
    n=split(a,x,/[._]/); m=split(b,y,/[._]/); k=(n>m)?n:m
    for(i=1;i<=k;i++){ p=(i<=n)?x[i]+0:0; q=(i<=m)?y[i]+0:0; if(p>q) exit 0; if(p<q) exit 1 }
    exit 0 }'
}

# package id -> fix pack level: com.ibm.websphere.ND.v90_9.0.5029.20260825_1416 -> 9.0.5.29
pkg_level() {
  printf '%s\n' "$1" | awk -F_ '{ v=$2; n=split(v,p,"."); if(n<3){print ""; exit}
    printf "%d.%d.%d.%d\n", p[1], p[2], int(p[3]/1000), p[3]%1000 }'
}
# package id -> sortable version part
pkg_ver() { printf '%s\n' "${1#*_}"; }

# highest package id for an offering prefix from a list on stdin (optionally matching a level)
pick_pkg() { # OFFERING [LEVEL]
  local best="" id lvl re
  re=$(re_esc "$1")
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    if [ -n "${2:-}" ]; then
      lvl=$(pkg_level "$id"); [ "$lvl" = "$2" ] || continue
    fi
    if [ -z "$best" ] || ver_ge "$(pkg_ver "$id")" "$(pkg_ver "$best")"; then best=$id; fi
  done <<EOF
$(grep -oE "${re}_[0-9][0-9._]*[0-9]" | sort -u)
EOF
  printf '%s\n' "$best"
}

run() { # log and run a command; output goes to the log
  info "run: $*"
  "$@" >> "$LOG" 2>&1
}

# ------------------------------------------------------------------ arguments
WAS_HOME="" REPOS="" TARGET="" IMCL="" APPLY=0 ROLLBACK=0 STOP=0 RESTART=0 ADMIN_USER="" PWFILE=""
BACKUP_DIR="" SKIP_JAVA=0 MIN_FREE_MB=3072 LOG_DIR=/var/tmp/was_fixpack WARNINGS=0
need() { [ $# -ge 2 ] && [ -n "$2" ] || usage_err "$1 needs a value"; clean "$2" || usage_err "$1 contains control characters"; }
while [ $# -gt 0 ]; do
  case $1 in
    --was-home) need "$@"; WAS_HOME=$2; shift 2 ;;
    --repo) need "$@"; REPOS=$2; shift 2 ;;
    --target-level) need "$@"; TARGET=$2; shift 2 ;;
    --imcl) need "$@"; IMCL=$2; shift 2 ;;
    --apply) APPLY=1; shift ;;
    --rollback) ROLLBACK=1; shift ;;
    --stop) STOP=1; shift ;;
    --restart) RESTART=1; shift ;;
    --admin-user) need "$@"; ADMIN_USER=$2; shift 2 ;;
    --password-file) need "$@"; PWFILE=$2; shift 2 ;;
    --backup-dir) need "$@"; BACKUP_DIR=$2; shift 2 ;;
    --skip-java) SKIP_JAVA=1; shift ;;
    --min-free-mb) need "$@"; MIN_FREE_MB=$2; shift 2 ;;
    --log-dir) need "$@"; LOG_DIR=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --version) echo "$ME $VERSION"; exit 0 ;;
    *) usage_err "unknown option: $1" ;;
  esac
done

[ -n "$WAS_HOME" ] || usage_err "--was-home is required"
case $WAS_HOME in /*) ;; *) usage_err "--was-home must be an absolute path" ;; esac
WAS_HOME=${WAS_HOME%/}
[ $ROLLBACK = 1 ] || [ -n "$REPOS" ] || usage_err "--repo is required"
[ $ROLLBACK = 1 ] && [ -n "$TARGET" ] && usage_err "--target-level cannot be used with --rollback"
[ -z "$TARGET" ] || printf '%s' "$TARGET" | grep -Eq '^(8\.5\.5|9\.0\.5)\.[0-9]{1,3}$' || usage_err "--target-level must look like 9.0.5.29 or 8.5.5.31"
printf '%s' "$MIN_FREE_MB" | grep -Eq '^[0-9]{1,7}$' || usage_err "--min-free-mb must be a number"
[ $RESTART = 0 ] || [ $STOP = 1 ] || usage_err "--restart needs --stop"
[ -z "$PWFILE" ] || [ -n "$ADMIN_USER" ] || usage_err "--password-file needs --admin-user"
case $LOG_DIR in /*) ;; *) usage_err "--log-dir must be an absolute path" ;; esac
[ -z "$BACKUP_DIR" ] || case $BACKUP_DIR in /*) ;; *) usage_err "--backup-dir must be an absolute path" ;; esac
OLDIFS=$IFS; IFS=,
for r in $REPOS; do
  case $r in /*|https://*) ;; *) IFS=$OLDIFS; usage_err "repository must be an absolute path or https:// URL: $r" ;; esac
  case $r in -*) IFS=$OLDIFS; usage_err "bad repository: $r" ;; esac
  case $r in https://*@*) IFS=$OLDIFS; usage_err "do not put credentials in a repository URL; use an IM keyring / credential store" ;; esac
done
IFS=$OLDIFS

# ------------------------------------------------------------------ log and lock
[ -L "$LOG_DIR" ] && usage_err "--log-dir is a symlink: $LOG_DIR"
mkdir -p "$LOG_DIR" 2>/dev/null && [ -w "$LOG_DIR" ] || usage_err "cannot write to log dir $LOG_DIR"
# the log dir holds the lock and logs; refuse one another user owns or can write to (e.g. pre-created in /var/tmp)
ld=$(ls -ld "$LOG_DIR" | awk '{m=$1; sub(/[.+@]$/,"",m); print m, $3}')
[ "${ld#* }" = "$(id -un)" ] || usage_err "log dir $LOG_DIR must be owned by $(id -un) (is: $ld)"
case ${ld%% *} in d????w????|d???????w?) usage_err "log dir $LOG_DIR is group/world writable (is: ${ld%% *})" ;; esac
STAMP=$(date '+%Y%m%d_%H%M%S')
LOG="$LOG_DIR/was_fixpack_${STAMP}_$$.log"
IMLOG="$LOG_DIR/was_fixpack_${STAMP}_$$_imcl.xml"
( set -C; : > "$LOG" ) 2>/dev/null || usage_err "cannot create log file $LOG"
info "$ME $VERSION  host=$(hostname)  user=$(id -un)  mode=$([ $ROLLBACK = 1 ] && echo rollback || { [ $APPLY = 1 ] && echo apply || echo precheck; })"
info "WAS_HOME=$WAS_HOME  repos=${REPOS:-none}  target=${TARGET:-highest}"

LOCK="$LOG_DIR/.lock_$(printf '%s' "$WAS_HOME" | cksum | awk '{print $1}')"
if ! mkdir "$LOCK" 2>/dev/null; then
  old=$(cat "$LOCK/pid" 2>/dev/null)
  if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then die 5 "another run (pid $old) is working on $WAS_HOME"; fi
  warn "removing stale lock from pid ${old:-unknown}"
  rm -rf "$LOCK"; mkdir "$LOCK" 2>/dev/null || die 5 "cannot take lock $LOCK"
fi
echo $$ > "$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT
trap 'die 3 "interrupted"' INT TERM HUP

# ------------------------------------------------------------------ prechecks
FAIL=0
fail() { log FAIL "$*"; FAIL=$((FAIL + 1)); }

[ -d "$WAS_HOME" ] || die 2 "WAS_HOME not found: $WAS_HOME"
[ -x "$WAS_HOME/bin/versionInfo.sh" ] || die 2 "not a WAS install root (no bin/versionInfo.sh): $WAS_HOME"

owner=$(ls -ld "$WAS_HOME" | awk '{print $3}')
me=$(id -un)
[ "$owner" = "$me" ] || fail "$WAS_HOME is owned by $owner but this runs as $me; run as the installation owner"

# imcl
if [ -z "$IMCL" ]; then
  for c in /opt/IBM/InstallationManager/eclipse/tools/imcl "$HOME/IBM/InstallationManager/eclipse/tools/imcl" \
           /opt/IBM/InstallationManager/eclipse/imcl /usr/IBM/InstallationManager/eclipse/tools/imcl \
           "$(dirname "$WAS_HOME")/InstallationManager/eclipse/tools/imcl"; do
    [ -x "$c" ] && { IMCL=$c; break; }
  done
fi
[ -n "$IMCL" ] && [ -x "$IMCL" ] || die 2 "imcl not found; pass --imcl /path/to/eclipse/tools/imcl"
IM_VER=$("$IMCL" version 2>/dev/null | awk -F': *' '/^Version/{print $2; exit}')
info "imcl=$IMCL  version=${IM_VER:-unknown}"
if [ -z "$IM_VER" ]; then fail "could not read the Installation Manager version"
elif ! ver_ge "$IM_VER" 1.8.5; then fail "Installation Manager $IM_VER is older than 1.8.5 (required by current fix packs); upgrade IM first"; fi

# installed packages in this install root
INSTALLED=$("$IMCL" listInstalledPackages -long 2>>"$LOG" | awk -F' : ' -v d="$WAS_HOME" '{ p=$1; sub(/[ \/]+$/,"",p); if (p==d) print $2 }')
[ -n "$INSTALLED" ] || die 2 "Installation Manager has no packages registered for $WAS_HOME (wrong IM, or wrong user/mode?)"
WAS_PKG=$(printf '%s\n' "$INSTALLED" | grep -E '^com\.ibm\.websphere\.(ND|BASE)\.v(85|90)_' | head -1)
[ -n "$WAS_PKG" ] || die 2 "no WAS ND/Base 8.5 or 9.0 package in $WAS_HOME: $(printf '%s' "$INSTALLED" | tr '\n' ' ')"
OFFERING=${WAS_PKG%%_*}
CUR_LEVEL=$(pkg_level "$WAS_PKG")
case $OFFERING in
  *.v85) LINE=8.5.5; JAVA_OFFERS="com.ibm.websphere.IBMJAVA.v80 com.ibm.websphere.IBMJAVA.v71 com.ibm.websphere.IBMJAVA.v70" ;;
  *.v90) LINE=9.0.5; JAVA_OFFERS="com.ibm.java.jdk.v8" ;;
esac
info "installed: $WAS_PKG  (level $CUR_LEVEL, line $LINE)"
case $CUR_LEVEL in 9.0.0.*) warn "9.0.0.x install: the jump to 9.0.5 covers many changes; allow extra regression testing" ;; esac
[ -z "$TARGET" ] || case $TARGET in "$LINE".*) ;; *) die 2 "--target-level $TARGET does not match the installed $LINE line" ;; esac

JAVA_PKG=""
for j in $JAVA_OFFERS; do
  p=$(printf '%s\n' "$INSTALLED" | grep -E "^$(re_esc "$j")_" | head -1)
  [ -n "$p" ] || continue
  case $j in *v70|*v71) warn "Java 7 package installed ($p); Java 7 is out of support, enable Java 8 for every profile (managesdk)" ;;
             *) JAVA_PKG=$p ;; esac
done
[ $LINE = 8.5.5 ] && [ -z "$JAVA_PKG" ] && warn "no Java 8 package (com.ibm.websphere.IBMJAVA.v80) installed; profiles may still be on Java 6/7"
info "installed Java package: ${JAVA_PKG:-none}"

# profiles (from the profile registry, so no JVM is started)
PROFILES=""
REG="$WAS_HOME/properties/profileRegistry.xml"
if [ -r "$REG" ]; then
  PROFILES=$(grep -o 'path="[^"]*"' "$REG" | sed 's/^path="//; s/"$//')
fi
info "profiles: $(printf '%s' "${PROFILES:-none}" | tr '\n' ' ')"

# running processes from this install root: "pid profile_path server_name"
running() {
  ps -eo pid=,args= 2>/dev/null | awk -v h="$WAS_HOME/" '
    index($0, h) && /java/ && !/awk/ {
      prof=""; for(i=2;i<=NF;i++) if ($i ~ /^-Duser\.install\.root=/) { prof=$i; sub(/^-Duser\.install\.root=/,"",prof) }
      if (prof != "") print $1, prof, $NF }'
}
RUNNING=$(running)
if [ -n "$RUNNING" ]; then
  info "running WAS processes:"; printf '%s\n' "$RUNNING" | while read -r l; do info "   $l"; done
  if [ $STOP = 0 ]; then
    if [ $APPLY = 1 ] || [ $ROLLBACK = 1 ]; then fail "WAS processes are running from $WAS_HOME; stop them or pass --stop"
    else warn "WAS processes are running; --apply will need them stopped (or --stop)"; fi
  fi
fi

# free space
free_mb() { df -Pk "$1" 2>/dev/null | awk 'NR==2{print int($4/1024)}'; }
F=$(free_mb "$WAS_HOME")
info "free space in $WAS_HOME filesystem: ${F:-?} MB (need $MIN_FREE_MB)"
[ -n "$F" ] && [ "$F" -ge "$MIN_FREE_MB" ] || fail "not enough free space in the $WAS_HOME filesystem"
T=$(free_mb "${TMPDIR:-/tmp}")
[ -z "$T" ] || [ "$T" -ge 1024 ] || warn "less than 1 GB free in ${TMPDIR:-/tmp} (IM extracts there)"

# password file
ADMIN_ARGS=()
if [ -n "$PWFILE" ]; then
  if [ ! -f "$PWFILE" ] || [ -L "$PWFILE" ]; then fail "password file is not a regular file: $PWFILE"
  else
    # strip the SELinux / ACL marker ('.', '+', '@') that ls appends on Linux and macOS
    perms=$(ls -l "$PWFILE" | awk '{m=$1; sub(/[.+@]$/,"",m); print m, $3}')
    case $perms in "-rw------- $me"|"-r-------- $me") ;; *) fail "password file must be mode 600/400 and owned by $me (is: $perms)" ;; esac
  fi
fi

# current level and iFixes, for the record
info "versionInfo before:"; "$WAS_HOME/bin/versionInfo.sh" -maintenancePackages >> "$LOG" 2>&1 || warn "versionInfo.sh -maintenancePackages failed"

# ------------------------------------------------------------------ pick what to install
NEW_WAS="" NEW_JAVA=""
if [ $ROLLBACK = 0 ]; then
  AVAIL=$("$IMCL" listAvailablePackages -repositories "$REPOS" -long 2>>"$LOG")
  [ -n "$AVAIL" ] || die 2 "no packages found in the repositories (check paths, access and credentials): $REPOS"
  NEW_WAS=$(printf '%s\n' "$AVAIL" | pick_pkg "$OFFERING" "$TARGET")
  [ -n "$NEW_WAS" ] || die 2 "no $OFFERING package${TARGET:+ at level $TARGET} in the repositories"
  NEW_LEVEL=$(pkg_level "$NEW_WAS")
  info "repository offers: $NEW_WAS  (level $NEW_LEVEL)"
  if [ "$(pkg_ver "$NEW_WAS")" = "$(pkg_ver "$WAS_PKG")" ]; then
    info "already at $CUR_LEVEL - nothing to install"; NOTHING=1
  elif ver_ge "$(pkg_ver "$WAS_PKG")" "$(pkg_ver "$NEW_WAS")"; then
    die 2 "repository level $NEW_LEVEL is older than the installed $CUR_LEVEL; use --rollback to go back"
  fi
  if [ -n "$JAVA_PKG" ] && [ $SKIP_JAVA = 0 ]; then
    JOFF=${JAVA_PKG%%_*}
    NEW_JAVA=$(printf '%s\n' "$AVAIL" | pick_pkg "$JOFF")
    if [ -z "$NEW_JAVA" ]; then fail "no $JOFF package in the repositories; add the IBM Java SDK repository for this fix pack or pass --skip-java"
    elif [ "$(pkg_ver "$NEW_JAVA")" = "$(pkg_ver "$JAVA_PKG")" ] || ver_ge "$(pkg_ver "$JAVA_PKG")" "$(pkg_ver "$NEW_JAVA")"; then
      info "Java package already at $JAVA_PKG"; NEW_JAVA=""
    else info "repository offers Java: $NEW_JAVA"; fi
  fi
fi

if [ $FAIL -gt 0 ]; then die 2 "$FAIL precheck(s) failed - see $LOG"; fi
info "prechecks passed ($WARNINGS warning(s))"
if [ "${NOTHING:-0}" = 1 ] && [ -z "$NEW_JAVA" ]; then info "nothing to do"; exit 0; fi
if [ $APPLY = 0 ] && [ $ROLLBACK = 0 ]; then
  info "precheck only: would install ${NEW_WAS} ${NEW_JAVA} into $WAS_HOME; rerun with --apply"
  exit 0
fi

# ------------------------------------------------------------------ stop / start
if [ -n "$ADMIN_USER" ]; then
  ADMIN_ARGS=(-username "$ADMIN_USER")
  if [ -n "$PWFILE" ]; then ADMIN_ARGS+=(-password "$(head -1 "$PWFILE")"); fi
fi
# run a stop script; the admin arguments are passed but never logged
stop_cmd() { # SCRIPT [SERVER]
  info "run: $1 ${2:-}"
  "$1" ${2:+"$2"} ${ADMIN_ARGS[@]+"${ADMIN_ARGS[@]}"} >> "$LOG" 2>&1
}

stop_all() {
  local pid prof srv kind
  for kind in app nodeagent dmgr; do
    while read -r pid prof srv; do
      [ -n "$pid" ] || continue
      case $srv in nodeagent) [ $kind = nodeagent ] || continue ;; dmgr) [ $kind = dmgr ] || continue ;; *) [ $kind = app ] || continue ;; esac
      case $kind in
        app) stop_cmd "$prof/bin/stopServer.sh" "$srv" ;;
        nodeagent) stop_cmd "$prof/bin/stopNode.sh" ;;
        dmgr) stop_cmd "$prof/bin/stopManager.sh" ;;
      esac || warn "stop of $srv in $prof returned non-zero"
    done <<EOF
$RUNNING
EOF
  done
  local i=0
  while [ -n "$(running)" ] && [ $i -lt 60 ]; do sleep "${WAS_FP_POLL_SECS:-5}"; i=$((i + 1)); done
  [ -z "$(running)" ] || die 3 "processes still running after stop: $(running | tr '\n' ' ')"
  info "all WAS processes from $WAS_HOME stopped"
}

start_all() {
  local pid prof srv kind
  for kind in dmgr nodeagent app; do
    while read -r pid prof srv; do
      [ -n "$pid" ] || continue
      case $srv in nodeagent) [ $kind = nodeagent ] || continue ;; dmgr) [ $kind = dmgr ] || continue ;; *) [ $kind = app ] || continue ;; esac
      case $kind in
        app) run "$prof/bin/startServer.sh" "$srv" ;;
        nodeagent) run "$prof/bin/startNode.sh" ;;
        dmgr) run "$prof/bin/startManager.sh" ;;
      esac || warn "start of $srv in $prof failed - check its logs"
    done <<EOF
$RUNNING
EOF
  done
}

# clear the OSGi cache of every profile (profile paths are one per line and may contain spaces)
osgi_all() {
  local p
  while IFS= read -r p; do
    [ -n "$p" ] && [ -x "$p/bin/osgiCfgInit.sh" ] || continue
    run "$p/bin/osgiCfgInit.sh" -all || warn "osgiCfgInit failed in $p"
  done <<EOF
$PROFILES
EOF
}

if [ -n "$RUNNING" ]; then stop_all; fi

# ------------------------------------------------------------------ rollback
if [ $ROLLBACK = 1 ]; then
  RB=("$OFFERING")
  [ -n "$JAVA_PKG" ] && [ $SKIP_JAVA = 0 ] && RB+=("${JAVA_PKG%%_*}")
  run "$IMCL" rollback "${RB[@]}" -installationDirectory "$WAS_HOME" -log "$IMLOG" || die 3 "imcl rollback failed - see $LOG and $IMLOG"
  AFTER=$("$IMCL" listInstalledPackages -long 2>>"$LOG" | awk -F' : ' -v d="$WAS_HOME" '{p=$1; sub(/[ \/]+$/,"",p); if(p==d) print $2}' | grep "^$(re_esc "$OFFERING")_" | head -1)
  info "after rollback: ${AFTER:-unknown} (level $(pkg_level "${AFTER:-x_0.0.0}"))"
  osgi_all
  [ $RESTART = 1 ] && start_all
  info "rollback finished ($WARNINGS warning(s)); log $LOG"
  exit 0
fi

# ------------------------------------------------------------------ backup
if [ -n "$BACKUP_DIR" ]; then
  [ -L "$BACKUP_DIR" ] && die 3 "--backup-dir is a symlink: $BACKUP_DIR"
  mkdir -p "$BACKUP_DIR" || die 3 "cannot create $BACKUP_DIR"
  need_mb=$(du -sk "$WAS_HOME" 2>/dev/null | awk '{print int($1/1024)}')
  have_mb=$(free_mb "$BACKUP_DIR")
  [ -n "$have_mb" ] && [ "$have_mb" -gt "${need_mb:-0}" ] || die 3 "not enough space in $BACKUP_DIR for the install root (${need_mb} MB needed, ${have_mb:-?} MB free)"
  while IFS= read -r p; do
    [ -n "$p" ] && [ -x "$p/bin/backupConfig.sh" ] || continue
    run "$p/bin/backupConfig.sh" "$BACKUP_DIR/$(basename "$p")_config_$STAMP.zip" -nostop -logfile "$LOG_DIR/backupConfig_$(basename "$p")_$STAMP.log" \
      || die 3 "backupConfig failed for $p"
  done <<EOF
$PROFILES
EOF
  run tar -cf "$BACKUP_DIR/was_home_$STAMP.tar" -C "$(dirname "$WAS_HOME")" "$(basename "$WAS_HOME")" || die 3 "tar of $WAS_HOME failed"
  info "backup written to $BACKUP_DIR"
fi

# ------------------------------------------------------------------ install
PKGS=()
[ "${NOTHING:-0}" = 1 ] || PKGS+=("$NEW_WAS")
[ -z "$NEW_JAVA" ] || PKGS+=("$NEW_JAVA")
run "$IMCL" install "${PKGS[@]}" -repositories "$REPOS" -installationDirectory "$WAS_HOME" -acceptLicense -showProgress \
    -preferences com.ibm.cic.common.core.preferences.preserveDownloadedArtifacts=true -log "$IMLOG" \
  || die 3 "imcl install failed - see $LOG and $IMLOG; installation left at the previous level unless the log says otherwise"

# ------------------------------------------------------------------ verify
AFTER=$("$IMCL" listInstalledPackages -long 2>>"$LOG" | awk -F' : ' -v d="$WAS_HOME" '{p=$1; sub(/[ \/]+$/,"",p); if(p==d) print $2}')
for want in "${PKGS[@]}"; do
  printf '%s\n' "$AFTER" | grep -qxF "$want" || die 4 "after install Installation Manager does not list $want for $WAS_HOME"
done
VI=$("$WAS_HOME/bin/versionInfo.sh" -maintenancePackages 2>&1); printf '%s\n' "$VI" >> "$LOG"
WANT_LEVEL=$(pkg_level "${NEW_WAS:-$WAS_PKG}")
printf '%s\n' "$VI" | grep -Eq "^Version[[:space:]]+$(re_esc "$WANT_LEVEL")\$" || die 4 "versionInfo.sh does not report $WANT_LEVEL"
info "verified: WAS $WANT_LEVEL${NEW_JAVA:+, Java $NEW_JAVA}"

osgi_all

[ $RESTART = 1 ] && [ -n "$RUNNING" ] && start_all
info "fix pack applied ($WARNINGS warning(s)). Next: check any iFixes not included in the pack (versionInfo above), sync nodes, test. Log: $LOG"
exit 0
