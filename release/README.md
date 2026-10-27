# Releasing mautic 5.2.3-2

The image is the released 5.2.3-1 image with four start-up files replaced and
the database password variables removed (see Dockerfile.release):

- MySQL listens on 127.0.0.1 only (`sources/mysqld.cnf` and the service
  command line), and the start-up script drops `root@'%'`.
- A new install gets a random root password, stored in
  `/home/appbox/config/mysql/client.cnf` (mode 0600) and in Mautic's
  `config/local.php`. An existing install keeps its password, which the
  start-up script reads from `config/local.php`.
- No password is passed on a command line, written to the crontab (the backup
  job uses `--defaults-file`) or printed to the container log.
- An installed Mautic whose MySQL root has no password refuses to start.

The start-up scripts run once per container, so an existing install picks up
the change when it is updated (re-created) to 5.2.3-2.

## Build, gate, push

From a clean checkout of branch `php-multipart-fix` on the Mac, after pushing:

    release/build-on-builder.sh trial      # build and gate, never pushes
    release/build-on-builder.sh release    # build, gate, push, print digest

`release/release-gate.py` is the gate. It compares every file and setting
with 5.2.3-1, installs 5.2.3-1 as a negative control, upgrades that install to
the new image, restarts it, installs the new image fresh, restarts that, and
checks that an installed Mautic with a passwordless MySQL root does not start.
It pushes nothing; the build script pushes only after it passes and the
registry reports the tag absent.

The 5.2.3-1 release (PHP security update) used `release/verify-image.sh`.
