#!/bin/bash
# Copyright (c) 2026 Shivraj Mudaliyar. SPDX-License-Identifier: MIT. Provided "as is", without warranty (see LICENSE).
# run_tests.sh - unit, penetration and stress tests for was_fixpack_install.sh against a mock imcl and fake WAS trees.
# Usage: BASH_BIN=/path/to/bash tests/run_tests.sh   (shell to run the script under; default bash on PATH)
# Writes tests/out/results_<bash version>.csv and exits non-zero if any test fails.

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
SCRIPT="$ROOT/was_fixpack_install.sh"
MOCKS="$ROOT/tests/mocks"
BASH_BIN=${BASH_BIN:-bash}
BV=$("$BASH_BIN" -c 'echo ${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}')
OUTDIR="$ROOT/tests/out"; mkdir -p "$OUTDIR"
RES="$OUTDIR/results_bash$BV.csv"
T=$(mktemp -d "${TMPDIR:-/tmp}/wasfptest.XXXXXX"); T=$(cd "$T" && pwd -P)
cleanup() { pkill -f "$T/" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
echo "id,stage,shell,test,result,detail" > "$RES"
PASS=0; FAIL=0; N=0
export WAS_FP_POLL_SECS=1

record() { # STAGE NAME OK DETAIL
  N=$((N + 1))
  if [ "$3" = 1 ]; then r=PASS; PASS=$((PASS + 1)); else r=FAIL; FAIL=$((FAIL + 1)); fi
  # keep local paths and the user name out of the results
  d=$(printf '%s' "$4" | sed -e "s|$T|<tmp>|g" -e "s|/[^ ]*/wasfptest\.[A-Za-z0-9]*|<tmp>|g" -e "s/ $(id -un)\([) ]\)/ <user>\1/g" -e "s/ $(id -un)\$/ <user>/" | tr '\n",' '  ;' | cut -c1-220)
  printf '%s,%s,bash%s,"%s",%s,"%s"\n' "$N" "$1" "$BV" "$2" "$r" "$d" >> "$RES"
  printf '%-4s %-6s %-5s %s %s\n' "$N" "$1" "$r" "$2" "$([ $r = FAIL ] && echo "-- $d")"
}

# fresh environment: NAME LEVEL [JAVA_PKG] -> sets W (WAS_HOME), S (IM state), R (repo dir), L (log dir)
env_new() {
  E="$T/$1"; W="$E/AppServer"; S="$E/im"; R="$E/repo"; L="$E/logs"
  rm -rf "$E"; mkdir -p "$R" "$L"
  "$MOCKS/mkwas.sh" "$W" "$2" "$S" "${3:-}"
  export FAKE_IM_STATE="$S"
  unset FAKE_IM_VER FAKE_INSTALL_FAIL FAKE_NO_VI_UPDATE
}
repo() { for p in "$@"; do echo "$p : name : x"; done > "$R/packages.txt"; }
fp() { # run the script with common args plus extras
  OUT=$("$BASH_BIN" "$SCRIPT" --was-home "$W" --repo "$R" --imcl "$MOCKS/imcl" --log-dir "$L" --min-free-mb 1 "$@" 2>&1 </dev/null); RC=$?
}
lvl() { cat "$W/.vi_level"; }
inst() { awk -F' : ' '{print $2}' "$S/installed" | tr '\n' ' '; }
expect_rc() { # STAGE NAME WANT_RC [GREP_PATTERN]
  ok=1; [ "$RC" = "$3" ] || ok=0
  [ -z "${4:-}" ] || printf '%s' "$OUT" | grep -Eq -- "$4" || ok=0
  record "$1" "$2" "$ok" "rc=$RC want $3 pattern=${4:-} :: $(printf '%s' "$OUT" | grep -E 'ERROR|FAIL|WARN|nothing|verified' | tail -3)"
}
start_jvm() { # PROFILE SERVER
  nohup "$W/java/8.0/bin/java" -Duser.install.root="$W/profiles/$1" com.ibm.ws.runtime.WsServer cfg cell node "$2" >/dev/null 2>&1 &
  disown $! 2>/dev/null
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do jvms | grep -qw -- "$2" && return; sleep 0.25; done
}
jvms() { ps -eo args= | grep -F -- "-Duser.install.root=$W/" | grep -v grep | awk '{print $NF}' | sort | tr '\n' ' '; }

P90_27=com.ibm.websphere.ND.v90_9.0.5027.20260310_1200
P90_28=com.ibm.websphere.ND.v90_9.0.5028.20260601_1200
P90_29=com.ibm.websphere.ND.v90_9.0.5029.20260825_1416
P85_31=com.ibm.websphere.ND.v85_8.5.5031.20260825_1416
J90_65=com.ibm.java.jdk.v8_8.0.8065.20260410_0645
J90_70=com.ibm.java.jdk.v8_8.0.8070.20260702_0501
J85_65=com.ibm.websphere.IBMJAVA.v80_8.0.8065.20260410_0645
J85_70=com.ibm.websphere.IBMJAVA.v80_8.0.8070.20260702_0501

# ======================= UNIT =======================
OUT=$("$BASH_BIN" "$SCRIPT" --help 2>&1); RC=$?; expect_rc UNIT "--help exits 0" 0 "Usage:"
OUT=$("$BASH_BIN" "$SCRIPT" --repo /x 2>&1); RC=$?; expect_rc UNIT "missing --was-home -> usage 1" 1 "required"
OUT=$("$BASH_BIN" "$SCRIPT" --was-home rel/path --repo /x 2>&1); RC=$?; expect_rc UNIT "relative --was-home -> 1" 1 "absolute"
OUT=$("$BASH_BIN" "$SCRIPT" --was-home /x --repo /x --target-level 9.0.5 2>&1); RC=$?; expect_rc UNIT "malformed --target-level -> 1" 1 "target-level"
OUT=$("$BASH_BIN" "$SCRIPT" --was-home /x --repo /x --restart 2>&1); RC=$?; expect_rc UNIT "--restart without --stop -> 1" 1 "needs --stop"
OUT=$("$BASH_BIN" "$SCRIPT" --was-home /x --repo /x --bogus 2>&1); RC=$?; expect_rc UNIT "unknown option -> 1" 1 "unknown option"
OUT=$("$BASH_BIN" "$SCRIPT" --was-home /x 2>&1); RC=$?; expect_rc UNIT "missing --repo -> 1" 1 "--repo is required"

env_new u1 9.0.5.27 "$J90_65"; repo "$P90_28" "$P90_29" "$J90_70"
fp; expect_rc UNIT "9.0.5.27 precheck picks highest 9.0.5.29 + Java, no change" 0 "would install $P90_29 $J90_70"
[ "$(lvl)" = 9.0.5.27 ] && ! grep -q '^install' "$S/calls"; record UNIT "precheck makes no changes" $([ $? = 0 ] && echo 1 || echo 0) "level=$(lvl)"
fp --apply; expect_rc UNIT "9.0.5 --apply installs fix pack and Java" 0 "verified: WAS 9.0.5.29"
[ "$(lvl)" = 9.0.5.29 ] && inst | grep -q "$J90_70"; record UNIT "installed level 9.0.5.29 + SR8 FP70" $([ $? = 0 ] && echo 1 || echo 0) "$(inst)"
grep -q 'osgiCfgInit -all' "$S/profile_calls"; record UNIT "osgiCfgInit run for profiles" $([ $? = 0 ] && echo 1 || echo 0) ""
grep -q 'preserveDownloadedArtifacts=true' "$S/calls"; record UNIT "imcl keeps rollback artifacts" $([ $? = 0 ] && echo 1 || echo 0) ""
fp --apply; expect_rc UNIT "second run: already at level -> nothing to do" 0 "nothing to (install|do)"

env_new u2 8.5.5.29 "$J85_65"; repo "$P85_31" "$J85_70" "$P90_29"
fp --apply; expect_rc UNIT "8.5.5.29 --apply -> 8.5.5.31 with IBMJAVA.v80" 0 "verified: WAS 8.5.5.31"
inst | grep -q "$J85_70"; record UNIT "8.5.5 Java offering updated, 9.0 package ignored" $([ $? = 0 ] && ! inst | grep -q v90 && echo 1 || echo 0) "$(inst)"

env_new u3 9.0.5.27 "$J90_65"; repo "$P90_28" "$P90_29" "$J90_70"
fp --target-level 9.0.5.28 --apply; expect_rc UNIT "--target-level 9.0.5.28 installs that level" 0 "verified: WAS 9.0.5.28"
fp --target-level 8.5.5.31; expect_rc UNIT "target from other line -> 2" 2 "does not match"
fp --target-level 9.0.5.30; expect_rc UNIT "target not in repo -> 2" 2 "no com.ibm.websphere.ND.v90 package at level"

env_new u4 9.0.5.29; repo "$P90_28"
fp --apply; expect_rc UNIT "repo older than installed -> 2" 2 "older than the installed"
env_new u5 9.0.5.27; repo "$P90_29"; export FAKE_IM_VER=1.8.4
fp; expect_rc UNIT "Installation Manager 1.8.4 -> 2" 2 "older than 1.8.5"
env_new u6 9.0.5.27 "$J90_65"; repo "$P90_29"
fp --apply; expect_rc UNIT "Java installed but no Java repo -> 2" 2 "IBM Java SDK repository"
fp --apply --skip-java; expect_rc UNIT "--skip-java installs WAS only" 0 "verified: WAS 9.0.5.29"
env_new u7 9.0.5.27; repo "$P90_29"
fp --min-free-mb 9999999; expect_rc UNIT "not enough disk space -> 2" 2 "free space"
env_new u8 9.0.5.27; repo "$P90_29"; export FAKE_INSTALL_FAIL=1
fp --apply; expect_rc UNIT "imcl install failure -> 3" 3 "imcl install failed"
env_new u9 9.0.5.27; repo "$P90_29"; export FAKE_NO_VI_UPDATE=1
fp --apply; expect_rc UNIT "versionInfo not at new level -> 4" 4 "does not report 9.0.5.29"
env_new u10 8.5.5.29 com.ibm.websphere.IBMJAVA.v70_7.0.9000.20200101_0000; repo "$P85_31"
fp; expect_rc UNIT "8.5.5 with only Java 7 -> warnings" 0 "Java 7 package installed"
env_new u11 9.0.0.11; repo "$P90_29"
fp; expect_rc UNIT "9.0.0.x warns about the jump" 0 "9.0.0.x install"
env_new u12 9.0.5.27; repo "$P90_29"; echo "/other/AppServer : $P90_27 : x : x" > "$S/installed"
fp; expect_rc UNIT "no IM packages for this WAS_HOME -> 2" 2 "no packages registered"
env_new u13 9.0.5.27; repo "$P90_29"; : > "$R/packages.txt"
fp; expect_rc UNIT "empty repository -> 2" 2 "no packages found"
env_new u14 9.0.5.27; repo "$P90_29"
OUT=$("$BASH_BIN" "$SCRIPT" --was-home "$W/" --repo "$R" --imcl "$MOCKS/imcl" --log-dir "$L" --min-free-mb 1 2>&1); RC=$?
expect_rc UNIT "trailing slash on --was-home accepted" 0 "would install"

# processes: stop / restart / rollback / backup
env_new u20 9.0.5.27 "$J90_65"; repo "$P90_29" "$J90_70"
start_jvm Dmgr01 dmgr; start_jvm AppSrv01 nodeagent; start_jvm AppSrv01 server1
fp --apply; expect_rc UNIT "running JVMs and no --stop -> 2" 2 "stop them or pass --stop"
fp --apply --stop --restart; expect_rc UNIT "--stop --restart: stop, install, restart" 0 "verified: WAS 9.0.5.29"
sleep 1; j=$(jvms); [ "$j" = "dmgr nodeagent server1 " ]; record UNIT "same JVMs running after restart" $([ $? = 0 ] && echo 1 || echo 0) "jvms=$j"
o=$(grep -E '^(stop|start)' "$S/profile_calls" | awk '{print $1}' | tr '\n' ' ')
[ "$o" = "stopServer stopNode stopManager startManager startNode startServer " ]; record UNIT "stop app>node>dmgr, start dmgr>node>app" $([ $? = 0 ] && echo 1 || echo 0) "$o"
fp --rollback --stop; expect_rc UNIT "--rollback --stop returns to previous level" 0 "rollback finished"
[ "$(lvl)" = 9.0.5.27 ] && inst | grep -q "$J90_65"; record UNIT "rollback restored 9.0.5.27 + previous Java" $([ $? = 0 ] && echo 1 || echo 0) "$(lvl) $(inst)"
[ -z "$(jvms)" ]; record UNIT "rollback without --restart leaves JVMs stopped" $([ $? = 0 ] && echo 1 || echo 0) "$(jvms)"
env_new u21 9.0.5.27; repo "$P90_29"
fp --apply --backup-dir "$E/bk"; expect_rc UNIT "--backup-dir: backup then install" 0 "backup written"
n=$(ls "$E/bk" | grep -c -E '(Dmgr01|AppSrv01)_config_.*\.zip|was_home_.*\.tar'); [ "$n" = 3 ]; record UNIT "backupConfig per profile + tar of install root" $([ $? = 0 ] && echo 1 || echo 0) "files=$n"
env_new u22 9.0.5.27; repo "$P90_29"
fp --rollback; expect_rc UNIT "rollback with nothing to roll back -> 3" 3 "rollback failed"

# ======================= PEN =======================
env_new p1 9.0.5.27; repo "$P90_29"
W2="$E/App Server;touch pwn1;\$(touch pwn2);\`touch pwn3\`"; mv "$W" "$W2"
sed -i.bak "s|$W|$W2|" "$S/installed"; sed -i.bak "s|$W|$W2|g" "$W2/properties/profileRegistry.xml"; W=$W2
cd "$E"; fp --apply; cd "$ROOT"; expect_rc PEN "WAS_HOME with spaces, ; \$() and backticks handled as data" 0 "verified: WAS 9.0.5.29"
[ ! -e "$E/pwn1" ] && [ ! -e "$E/pwn2" ] && [ ! -e "$E/pwn3" ]; record PEN "no command executed from WAS_HOME string" $([ $? = 0 ] && echo 1 || echo 0) ""
n=$(grep -c 'osgiCfgInit -all' "$S/profile_calls"); [ "$n" = 2 ]; record PEN "profile paths with spaces kept whole (osgiCfgInit on both)" $([ $? = 0 ] && echo 1 || echo 0) "osgi calls=$n"
env_new p2 9.0.5.27; repo "$P90_29"
OUT=$("$BASH_BIN" "$SCRIPT" --was-home "$W" --repo "relative/repo" --imcl "$MOCKS/imcl" --log-dir "$L" 2>&1); RC=$?
expect_rc PEN "relative repository rejected" 1 "absolute path or https"
OUT=$("$BASH_BIN" "$SCRIPT" --was-home "$W" --repo "http://insecure.example/repo" --imcl "$MOCKS/imcl" --log-dir "$L" 2>&1); RC=$?
expect_rc PEN "plain http repository rejected" 1 "absolute path or https"
OUT=$("$BASH_BIN" "$SCRIPT" --was-home "$W" --repo "https://user:pw@repo.example/was" --imcl "$MOCKS/imcl" --log-dir "$L" 2>&1); RC=$?
expect_rc PEN "credentials in repository URL rejected" 1 "credentials in a repository URL"
mkdir -p "$E/wwlog"; chmod 777 "$E/wwlog"
OUT=$("$BASH_BIN" "$SCRIPT" --was-home "$W" --repo "$R" --imcl "$MOCKS/imcl" --log-dir "$E/wwlog" 2>&1); RC=$?
expect_rc PEN "world-writable --log-dir rejected" 1 "group/world writable"
OUT=$("$BASH_BIN" "$SCRIPT" --was-home "$W" --repo "$R" --target-level '9.0.5.29;id' --imcl "$MOCKS/imcl" --log-dir "$L" 2>&1); RC=$?
expect_rc PEN "--target-level with shell metacharacters rejected" 1 "target-level must"
OUT=$("$BASH_BIN" "$SCRIPT" --was-home "$W
/etc" --repo "$R" --imcl "$MOCKS/imcl" --log-dir "$L" 2>&1); RC=$?
expect_rc PEN "newline in --was-home rejected" 1 "control characters"
ln -s "$E/elsewhere" "$E/loglink"; mkdir -p "$E/elsewhere"
OUT=$("$BASH_BIN" "$SCRIPT" --was-home "$W" --repo "$R" --imcl "$MOCKS/imcl" --log-dir "$E/loglink" 2>&1); RC=$?
expect_rc PEN "symlinked --log-dir rejected" 1 "symlink"
ln -s "$E/elsewhere" "$E/bklink"
fp --apply --backup-dir "$E/bklink"; expect_rc PEN "symlinked --backup-dir rejected before install" 3 "symlink"
[ "$(lvl)" = 9.0.5.27 ]; record PEN "nothing installed after backup-dir refusal" $([ $? = 0 ] && echo 1 || echo 0) "$(lvl)"
env_new p3 9.0.5.27; repo "$P90_29"
printf '%s\n' 's3cr3t-Pa55' > "$E/pw"; chmod 644 "$E/pw"
fp --admin-user wasadmin --password-file "$E/pw"; expect_rc PEN "world-readable password file -> 2" 2 "mode 600"
chmod 600 "$E/pw"; start_jvm AppSrv01 server1
fp --apply --stop --admin-user wasadmin --password-file "$E/pw"; expect_rc PEN "600 password file accepted" 0 "verified"
grep -q -- '-username wasadmin -password s3cr3t-Pa55' "$S/profile_calls"; a=$?
! grep -rq 's3cr3t-Pa55' "$L"; b=$?
record PEN "password passed to stop script, never written to logs" $([ $a = 0 ] && [ $b = 0 ] && echo 1 || echo 0) "passed=$a logclean=$b"
env_new p4 9.0.5.27; repo "$P90_29" 'com.ibm.websphere.ND.v90_9.0.5099.20260101_0000;touch_pwn' 'com.ibm.websphere.ND.v90_9.0.5099$(id)'
fp; expect_rc PEN "malicious package ids in repo listing: only digits taken" 0 "would install com.ibm.websphere.ND.v90_9.0.5099.20260101_0000 +into"
env_new p5 9.0.5.27; repo "$P90_29"; echo "com.ibm.websphere.NDXv90_9.0.5099.20260101_0000 : x : x" >> "$R/packages.txt"
fp; expect_rc PEN "regex dots escaped (NDXv90 not taken as ND.v90)" 0 "would install $P90_29"
env_new p6 9.0.5.27; repo "$P90_29"
LK="$L/.lock_$(printf '%s' "$W" | cksum | awk '{print $1}')"; mkdir -p "$LK"; sleep 300 & HOLD=$!; echo $HOLD > "$LK/pid"
fp; expect_rc PEN "lock held by live process -> 5" 5 "another run"
kill $HOLD 2>/dev/null; wait $HOLD 2>/dev/null
fp; expect_rc PEN "stale lock removed and run continues" 0 "stale lock"
[ ! -d "$LK" ]; record PEN "lock released on exit" $([ $? = 0 ] && echo 1 || echo 0) ""
f=$(ls "$L"/was_fixpack_*.log | head -1); m=$(ls -l "$f" | awk '{m=$1; sub(/[.+@]$/,"",m); print m}')
case $m in -rw-r-----|-rw-------) ok=1 ;; *) ok=0 ;; esac; record PEN "log files not world-readable (umask 027)" $ok "$m"

# ======================= STRESS =======================
env_new s1 9.0.5.27; repo "$P90_29"
for i in $(seq 1 20); do ("$BASH_BIN" "$SCRIPT" --was-home "$W" --repo "$R" --imcl "$MOCKS/imcl" --log-dir "$L" --min-free-mb 1 >/dev/null 2>&1; echo $? > "$E/rc.$i") & done; wait
rcs=$(cat "$E"/rc.* | sort | uniq -c | tr -s ' ' | tr '\n' ' ')
bad=$(cat "$E"/rc.* | grep -cv -E '^(0|5)$'); zero=$(grep -lx 0 "$E"/rc.* | wc -l | tr -d ' ')
[ "$bad" = 0 ] && [ "$zero" -ge 1 ]; record STRESS "20 concurrent prechecks: only 0 or 5 (lock), at least one ran" $([ $? = 0 ] && echo 1 || echo 0) "$rcs"
ls -d "$L"/.lock_* >/dev/null 2>&1; record STRESS "no lock left after concurrent runs" $([ $? != 0 ] && echo 1 || echo 0) ""
env_new s2 9.0.5.27; repo "$P90_29"
for i in $(seq 1 20); do ("$BASH_BIN" "$SCRIPT" --was-home "$W" --repo "$R" --imcl "$MOCKS/imcl" --log-dir "$L" --min-free-mb 1 --apply >/dev/null 2>&1; echo $? > "$E/rc.$i") & done; wait
c=$(grep -c '^install' "$S/calls"); [ "$(lvl)" = 9.0.5.29 ] && [ "$c" = 1 ]; record STRESS "20 concurrent --apply: installed exactly once" $([ $? = 0 ] && echo 1 || echo 0) "installs=$c level=$(lvl) rcs=$(cat "$E"/rc.* | sort | uniq -c | tr -s ' ' | tr '\n' ' ')"
env_new s3 9.0.5.27; : > "$R/packages.txt"
for a in $(seq 5000 5999); do echo "com.ibm.websphere.ND.v90_9.0.$a.20260101_0000 : n : x"; echo "com.ibm.websphere.ND.v85_8.5.$a.20260101_0000 : n : x"; done >> "$R/packages.txt"
t0=$(date +%s); fp; t1=$(date +%s)
expect_rc STRESS "2000-package repository: picks highest (9.0.5999)" 0 "v90_9.0.5999"
[ $((t1 - t0)) -lt 120 ]; record STRESS "2000-package repository handled in under 120 s" $([ $? = 0 ] && echo 1 || echo 0) "$((t1 - t0)) s"
env_new s4 9.0.5.27; repo "$P90_29"
for i in $(seq 1 50); do fp >/dev/null; [ $RC = 0 ] || break; done
n=$(ls "$L"/was_fixpack_*.log | wc -l | tr -d ' ')
[ $RC = 0 ] && [ "$n" = 50 ] && ! ls -d "$L"/.lock_* >/dev/null 2>&1; record STRESS "50 sequential runs: 50 separate logs, no lock left" $([ $? = 0 ] && echo 1 || echo 0) "logs=$n rc=$RC"

echo
echo "bash $BV: $PASS passed, $FAIL failed (of $N) -> $RES"
[ $FAIL = 0 ]
