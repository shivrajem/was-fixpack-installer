# was-fixpack-installer

One script to apply a WebSphere Application Server traditional fix pack to an **8.5.5.x or 9.0.5.x** installation (Network Deployment or Base) with IBM Installation Manager. The script reads what is installed and works out the version line itself, so the same command works on 8.5.5 and 9.0.5 hosts.

By default it only runs the prechecks and changes nothing. Pass `--apply` to install.

## What it does

1. **Prechecks**
   - You are the owner of the install root.
   - `imcl` is found and Installation Manager is 1.8.5 or later.
   - Installation Manager has a WAS package registered for this install root.
   - The Java package and its offering are found:
     - 9.0.5: `com.ibm.java.jdk.v8`
     - 8.5.5: `com.ibm.websphere.IBMJAVA.v80`. A warning is given for Java 7 or for no Java 8 package.
   - The profiles are read from `profileRegistry.xml`, and the WAS JVMs running from the install root are listed.
   - The install filesystem has enough free space.
   - The password file permissions are safe.
   - `versionInfo -maintenancePackages` is captured, including any iFixes.
2. **Choose the package.** It picks the highest WAS fix pack in the repositories, or the one given with `--target-level`, plus the matching Java SDK package. It refuses to downgrade, and does nothing if the install is already at that level.
3. **Stop** (`--stop`): application servers first, then the node agent, then the deployment manager. It waits until every JVM has exited.
4. **Back up** (`--backup-dir`): runs `backupConfig -nostop` for each profile and makes a tar of the install root.
5. **Install** with `imcl install <WAS pkg> <Java pkg>`. Installation Manager keeps the files it needs for rollback.
6. **Verify**:
   - Installation Manager lists the new packages for this install root.
   - `versionInfo.sh` reports the new level.
   - `osgiCfgInit.sh -all` runs for every profile.
7. **Restart** (`--restart`) whatever was running before: the deployment manager first, then the node agent, then the servers.

`--rollback` runs `imcl rollback` for the WAS and Java packages, which returns them to the previous level.

## Usage

```sh
# precheck (no changes)
./was_fixpack_install.sh --was-home /opt/IBM/WebSphere/AppServer \
    --repo /stage/was/9.0.5-WS-WAS-FP029,/stage/java/9.0.5-WS-IBMWASJAVA-FP029

# apply on a node: stop, back up, install, restart
./was_fixpack_install.sh --was-home /opt/IBM/WebSphere/AppServer \
    --repo /stage/was/9.0.5-WS-WAS-FP029,/stage/java/9.0.5-WS-IBMWASJAVA-FP029 \
    --apply --stop --restart --backup-dir /backup/was_fp029

# 8.5.5 host, specific level
./was_fixpack_install.sh --was-home /opt/IBM/WebSphere/AppServer --repo /stage/was855_fp31,/stage/java8_sr8fp70 \
    --target-level 8.5.5.31 --apply --stop

# roll back
./was_fixpack_install.sh --was-home /opt/IBM/WebSphere/AppServer --rollback --stop --restart
```

Run `--help` to see every option.

| Exit code | Meaning |
|---|---|
| 0 | OK, or nothing to do |
| 1 | Usage error |
| 2 | A precheck failed |
| 3 | Install, stop, backup or rollback failed |
| 4 | Post-install verification failed |
| 5 | Another run holds the lock for this install root |

Logs go to `/var/tmp/was_fixpack/` by default; change this with `--log-dir`. Each run writes:
- One script log.
- One Installation Manager XML log.

## Order in an ND cell

Run the script on the deployment manager host first, then on one node at a time:
- Drain each node from the plug-in or load balancer before running the script on it.
- Check the node after the script finishes.
- Put the node back into service before moving to the next one.

A deployment manager must be at the same or a higher level than its nodes. If you roll back, roll back the nodes before the deployment manager. See the patching plan for the full procedure.

## Notes and limits

- **Run as the installation owner**, in the same Installation Manager mode (admin, non-admin or group) that was used to install WAS.
- **Admin credentials:**
  - The preferred approach is to put them in each profile's `soap.client.props`. They then never appear on a command line.
  - With `--admin-user` and `--password-file`, the password is passed to `stopServer.sh`, `stopNode.sh` and `stopManager.sh` as `-password`. Other local users can see it in `ps` while those commands run. It is never written to the logs.
- **Repositories:**
  - Repositories must be absolute paths or `https://` URLs.
  - Put credentials for an authenticated repository in an Installation Manager keyring or credential store, not in the URL. The script rejects a URL that contains credentials.
- **iFixes:** iFixes that the new fix pack does not include are not reinstalled. Compare the before and after `versionInfo` output in the log, and get rebuilt iFixes from IBM if you need them.
- **Paths with spaces:** running JVMs are found by `-Duser.install.root=` in the process arguments, so an install root that contains spaces is not supported for `--stop`. IBM also advises against spaces in install paths.
- **Testing:** the script has been tested with unit, security and stress tests on bash 3.2, 5.1 and 5.2, but only against a simulated Installation Manager and WAS installation. Run it in precheck mode on a real host and try `--apply` in a non-production environment first.

## Licence

MIT. See `LICENSE`.
