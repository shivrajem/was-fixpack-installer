#!/bin/bash
# mkwas.sh DIR LEVEL STATE_DIR [JAVA_PKG]  - build a fake WAS install root registered in the mock IM state
D=$1 L=$2 S=$3 J=${4:-}
mkdir -p "$D/bin" "$D/properties" "$D/java/8.0/bin" "$S"
: > "$S/calls"; touch "$S/installed" "$S/history"
echo "$L" > "$D/.vi_level"
case $L in 8.5.5.*) off=com.ibm.websphere.ND.v85 ;; *) off=com.ibm.websphere.ND.v90 ;; esac
IFS=. read -r a b c f <<< "$L"
echo "$D : ${off}_$a.$b.$((c*1000+f)).20250101_0000 : IBM WebSphere Application Server Network Deployment : $L" >> "$S/installed"
[ -z "$J" ] || echo "$D : $J : IBM SDK : x" >> "$S/installed"
cat > "$D/bin/versionInfo.sh" <<VI
#!/bin/bash
H=\$(cd "\$(dirname "\$0")/.." && pwd)
printf 'Installed Product\nName                  IBM WebSphere Application Server Network Deployment\nVersion               %s\nID                    ND\n' "\$(cat "\$H/.vi_level")"
VI
cat > "$D/java/8.0/bin/java" <<'JV'
#!/bin/bash
# fake WAS JVM: stays alive until killed
while :; do sleep 1; done
JV
chmod +x "$D/bin/versionInfo.sh" "$D/java/8.0/bin/java"
reg="<profiles>"
for p in Dmgr01 AppSrv01; do
  P="$D/profiles/$p"; mkdir -p "$P/bin"
  reg="$reg<profile isDefault=\"false\" name=\"$p\" path=\"$P\" template=\"x\"/>"
  for s in stopServer stopNode stopManager startServer startNode startManager osgiCfgInit backupConfig; do
    cat > "$P/bin/$s.sh" <<SC
#!/bin/bash
echo "$s \$*" >> "$S/profile_calls"
P="$P"; D="$D"
case $s in
  stopServer) srv=\$1 ;; stopNode) srv=nodeagent ;; stopManager) srv=dmgr ;;
  startServer) srv=\$1 ;; startNode) srv=nodeagent ;; startManager) srv=dmgr ;;
esac
case $s in
  stop*) ps -eo pid=,args= | awk -v a="-Duser.install.root=\$P" -v s="\$srv" 'index(\$0,a) && \$NF==s && !/awk/ {print \$1}' | xargs kill 2>/dev/null ;;
  start*) nohup "\$D/java/8.0/bin/java" -Duser.install.root="\$P" com.ibm.ws.runtime.WsServer cfg cell node "\$srv" >/dev/null 2>&1 & ;;
  backupConfig) : > "\$1" ;;
esac
exit 0
SC
    chmod +x "$P/bin/$s.sh"
  done
done
echo "$reg</profiles>" > "$D/properties/profileRegistry.xml"
