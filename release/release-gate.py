#!/usr/bin/env python3
"""Release gate for repo.cylo.net/mautic:5.2.3-2.

Usage: release/release-gate.py <image>
  <image> is the release reference below, or local/mautic-trial:5.2.3-2.

Exits 0 only when the local image passes every check and the authenticated
registry definitively reports that the release tag does not exist. Any
indeterminate registry answer fails.

Checks:
  * image: no password in the configuration or history; every other setting
    and every file except the four replaced ones matches 5.2.3-1;
  * 5.2.3-1, fresh install (the negative control): MySQL listens on all
    addresses, root@'%' exists and another container can reach port 3306;
  * upgrade of that install to the new image with the same volumes, a restart,
    and a fresh install with the new image: Mautic login works, MySQL listens
    on 127.0.0.1 only, root@'%' is gone, another container cannot connect,
    passwordless root is refused, the existing password is kept on upgrade
    and a new random one is stored with mode 0600 on a fresh install, and no
    database password is in the container log, any process's arguments or
    environment, the crontab or the log and configuration directories;
  * on an installed Mautic whose MySQL root has no password, the start-up
    script refuses to continue.

Every container gets dummy install values and a stub install callback; nothing
here contacts api.cylo.io or a customer instance. Runs at most one MySQL
container at a time. To keep the first-start `apt install mysql-server` from
taking most of an hour on a busy builder disk, test containers get a dpkg
`force-unsafe-io` setting; it only skips dpkg's fsync calls. 5.2.3-1's
mysql.sh gives MySQL a fixed 10 seconds to start before configuring it; on a
busy builder that is too short (root keeps an empty password and the install
fails), so the 5.2.3-1 container gets a copy that also waits for MySQL to
answer. Nothing else in 5.2.3-1 is changed.
"""
import base64
import hashlib
import http.client
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

EXPECTED = 'repo.cylo.net/mautic:5.2.3-2'
TRIAL = 'local/mautic-trial:5.2.3-2'
# The current release (5.2.3-1), the baseline for files, settings and upgrade.
CURRENT = 'repo.cylo.net/mautic@sha256:3ddd2316159d803776a2b3ba187f883e3ecd8c02b9e85a8f6d1bfad3a059a6b6'
CHANGED_FILES = {
    '/scripts/mysql.sh': 'scripts/mysql.sh',
    '/scripts/mautic.sh': 'scripts/mautic.sh',
    '/etc/my_init.d/30_installer.sh': 'scripts/30_installer.sh',
    '/sources/mysqld.cnf': 'sources/mysqld.cnf',
}
REMOVED_ENV = {'MYSQL_ROOT_PASSWORD', 'MAUTIC_DB_PASSWORD', 'DB_PASS'}
CLIENT_CNF = '/home/appbox/config/mysql/client.cnf'
LOCAL_PHP = '/home/appbox/public_html/config/local.php'
INSTANCE_ID = '900000166'
READY_TIMEOUT = 60 * 60

repo_dir = Path(__file__).resolve().parent.parent
if len(sys.argv) != 2 or sys.argv[1] not in (EXPECTED, TRIAL):
    raise SystemExit('Usage: release-gate.py ' + EXPECTED + ' (or ' + TRIAL + ')')
image = sys.argv[1]
run_id = 'mautic-gate-' + secrets.token_hex(6)
work = Path(tempfile.mkdtemp(prefix=run_id + '-', dir=repo_dir.parent))
containers = []
secret_values = set()


def log(message):
    print(message, flush=True)


def redact(text):
    for value in sorted(secret_values, key=len, reverse=True):
        if value:
            text = text.replace(value, '[redacted]')
    return text


def run(args, data=None, timeout=600, check=True):
    p = subprocess.run(args, input=data, capture_output=True, timeout=timeout)
    if check and p.returncode:
        # Never print command arguments or unredacted output.
        raise RuntimeError('command failed (%s %s): %s' % (
            args[0], args[1] if len(args) > 1 else '',
            redact(p.stderr.decode(errors='replace'))[-1500:]))
    return p


def out(args, **kw):
    return run(args, **kw).stdout.decode(errors='replace')


def expect(condition, message):
    if not condition:
        raise AssertionError(message)


# ---------------------------------------------------------------- registry

def registry_absent():
    registry, rest = EXPECTED.split('/', 1)
    repository, tag = rest.rsplit(':', 1)
    config = json.loads(Path.home().joinpath('.docker/config.json').read_text())
    auth = config.get('auths', {}).get(registry, {}).get('auth')
    expect(auth, 'no stored credentials for ' + registry)
    accept = ', '.join([
        'application/vnd.oci.image.index.v1+json',
        'application/vnd.oci.image.manifest.v1+json',
        'application/vnd.docker.distribution.manifest.list.v2+json',
        'application/vnd.docker.distribution.manifest.v2+json'])

    def get(path):
        request = urllib.request.Request('https://' + registry + path, headers={
            'Authorization': 'Basic ' + auth, 'Accept': accept})
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                return response.status, response.read()
        except urllib.error.HTTPError as error:
            return error.code, error.read()

    status, _ = get('/v2/')
    expect(status == 200, 'registry API check returned HTTP %s' % status)
    status, _ = get('/v2/%s/manifests/%s' % (repository, CURRENT.split('@', 1)[1]))
    expect(status == 200, 'registry read of the current release returned HTTP %s; state is indeterminate' % status)
    status, body = get('/v2/%s/manifests/%s' % (repository, tag))
    if status == 200:
        raise AssertionError(EXPECTED + ' already exists in the registry; refusing to replace it')
    expect(status == 404 and b'MANIFEST_UNKNOWN' in body,
           'registry returned HTTP %s for %s; state is indeterminate' % (status, EXPECTED))
    log('PASS registry: current release readable; %s definitively absent (MANIFEST_UNKNOWN)' % EXPECTED)


# ------------------------------------------------------------------- image

MANIFEST_SCRIPT = r'''
set -e
prune='( -path /proc -o -path /sys -o -path /dev -o -path /etc/hostname -o -path /etc/hosts -o -path /etc/resolv.conf )'
find / $prune -prune -o -printf '%y %m %U %G %s %p\t%l\n' | sort > /tmp/tree
find / $prune -prune -o -type f -print0 | xargs -0 sha256sum | sort -k2 > /tmp/sums
find / $prune -prune -o -type f -print0 | xargs -0 getcap 2>/dev/null | sort > /tmp/caps || true
echo @@tree; cat /tmp/tree; echo @@sums; cat /tmp/sums; echo @@caps; cat /tmp/caps
'''


def manifest(ref):
    text = out(['docker', 'run', '--rm', '-i', '--network', 'none', '--entrypoint', 'sh', ref, '-s'],
               data=MANIFEST_SCRIPT.encode(), timeout=1800)
    sections, current = {}, None
    for line in text.splitlines():
        if line.startswith('@@'):
            current = line[2:]
            sections[current] = []
        elif current:
            sections[current].append(line)
    tree = {}
    for line in sections['tree']:
        meta, _, link = line.partition('\t')
        kind, mode, uid, gid, size, path = meta.split(' ', 5)
        if path in ('/tmp/tree', '/tmp/sums', '/tmp/caps', '/tmp'):
            continue
        tree[path] = (kind, mode, uid, gid, '' if kind == 'd' else size, link)
    sums = {}
    for line in sections['sums']:
        digest, path = line.split('  ', 1)
        if path not in ('/tmp/tree', '/tmp/sums', '/tmp/caps'):
            sums[path] = digest
    return tree, sums, sections['caps']


def check_image(old_password):
    current = json.loads(out(['docker', 'image', 'inspect', CURRENT]))[0]
    new = json.loads(out(['docker', 'image', 'inspect', image]))[0]
    expect(new['Os'] + '/' + new['Architecture'] == 'linux/amd64', 'image is not linux/amd64')
    current_env = dict(e.split('=', 1) for e in current['Config']['Env'])
    new_env = dict(e.split('=', 1) for e in new['Config']['Env'])
    expect(REMOVED_ENV <= set(current_env), 'the current release no longer has the expected password variables')
    expect(not any('PASS' in key for key in new_env), 'the new image still defines a password variable')
    expected_env = {k: v for k, v in current_env.items() if k not in REMOVED_ENV}
    expect(new_env == expected_env, 'environment differs from 5.2.3-1 beyond the removed password variables')
    for field in ('Cmd', 'Entrypoint', 'User', 'WorkingDir', 'ExposedPorts', 'Volumes', 'Labels',
                  'StopSignal', 'Healthcheck', 'Shell', 'OnBuild'):
        expect((new['Config'].get(field) or None) == (current['Config'].get(field) or None),
               'image config %s differs from 5.2.3-1' % field)
    log('PASS image config: password variables removed; command, user, ports, volumes, labels and other environment unchanged')

    history = out(['docker', 'history', '--no-trunc', '--format', '{{.CreatedBy}}', image])
    inspect_text = json.dumps(new)
    for text, where in ((history, 'history'), (inspect_text, 'configuration')):
        expect(old_password not in text, 'the shared database password is still in the image ' + where)
        expect(not re.search(r'(MYSQL_ROOT_PASSWORD|MAUTIC_DB_PASSWORD|DB_PASS)=', text),
               'a password variable is still set in the image ' + where)
    found = run(['docker', 'run', '--rm', '-i', '--network', 'none', '--entrypoint', 'sh', image, '-c',
                 'cat > /tmp/pattern; for d in /*; do case "$d" in /proc|/sys|/dev) ;; '
                 '*) grep -rlsF -D skip -f /tmp/pattern "$d" ;; esac; done | grep -vx /tmp/pattern; true'],
                data=old_password.encode() + b'\n', timeout=1800).stdout.decode().split()
    expect(not found, 'files in the image contain the shared database password: %s' % ', '.join(found))
    log('PASS image secrets: the shared database password is not in the configuration, history or any file')

    current_tree, current_sums, current_caps = manifest(CURRENT)
    new_tree, new_sums, new_caps = manifest(image)
    expect(set(current_tree) == set(new_tree), 'paths added or removed: %s' % sorted(
        set(current_tree) ^ set(new_tree))[:20])
    differing = sorted(p for p in current_tree if current_tree[p] != new_tree[p] and p not in CHANGED_FILES)
    expect(not differing, 'type, mode, owner, size or link target changed: %s' % differing[:20])
    differing = sorted(p for p in current_sums if current_sums[p] != new_sums.get(p) and p not in CHANGED_FILES)
    expect(not differing, 'file contents changed: %s' % differing[:20])
    expect(current_caps == new_caps, 'file capabilities changed')
    for path, source in CHANGED_FILES.items():
        expected = hashlib.sha256((repo_dir / source).read_bytes()).hexdigest()
        expect(new_sums.get(path) == expected, '%s does not match %s' % (path, source))
        expect(current_sums.get(path) != expected, '%s was not replaced' % path)
        kind, mode = new_tree[path][:2]
        expect((kind, mode, new_tree[path][2], new_tree[path][3]) ==
               ('f', '644' if path.startswith('/sources/') else '755', '0', '0'), '%s has the wrong mode or owner' % path)
    log('PASS image files: %d paths, all identical to 5.2.3-1 except the %d replaced files, which match Git'
        % (len(new_tree), len(CHANGED_FILES)))


# --------------------------------------------------------------- scenarios

CURL_SHIM = '''#!/bin/sh
# Release-gate stub: answers the Appbox install callback locally.
for a in "$@"; do
  case "$a" in
    https://api.cylo.io/v1/apps/installed/*|https://api.cylo.net/v1/apps/installed/*)
      echo "$a" >> /gate-cb/callbacks
      printf 'HTTP/1.1 200 OK\\r\\n\\r\\n{}\\n'
      exit 0 ;;
  esac
done
exec /usr/bin/curl "$@"
'''

admin_user = 'gateadmin'
admin_password = secrets.token_hex(12)
secret_values.add(admin_password)


def storage(name):
    base = work / name
    for sub in ('config', 'logs', 'mysql', 'public_html', 'cb'):
        (base / sub).mkdir(parents=True)
    return base


def launch(suffix, ref, volumes):
    name = run_id + '-' + suffix
    shim = work / 'curl-shim'
    dpkg = work / 'dpkg-unsafe-io'
    if not shim.exists():
        shim.write_text(CURL_SHIM)
        shim.chmod(0o755)
        dpkg.write_text('force-unsafe-io\n')
        dpkg.chmod(0o644)
    extra = []
    if ref == CURRENT:
        baseline_mysql = work / 'baseline-mysql.sh'
        if not baseline_mysql.exists():
            source = out(['docker', 'run', '--rm', '--network', 'none', '--entrypoint', 'cat', CURRENT,
                          '/scripts/mysql.sh'])
            start = '/usr/bin/mysqld_safe --defaults-file=/home/appbox/config/mysql/mysqld.cnf &\nsleep 10\n'
            expect(source.count(start) == 1, '5.2.3-1 mysql.sh no longer has the fixed 10 second wait')
            source = source.replace(start, start + 'until mysqladmin --no-defaults ping >/dev/null 2>&1; '
                                    'do sleep 2; done\n')
            baseline_mysql.write_text(source)
            baseline_mysql.chmod(0o755)
        extra = ['-v', '%s:/scripts/mysql.sh:ro' % baseline_mysql]
    run(['docker', 'run', '-d', '--platform', 'linux/amd64', '--name', name,
         '--label', 'appbox.release-gate=' + run_id, '--init',
         '--memory', '2g', '--memory-swap', '2g', '--memory-reservation', '1g',
         '--hostname', name + '.example.test', '-p', '127.0.0.1::80',
         '-v', '%s/config:/home/appbox/config' % volumes, '-v', '%s/logs:/home/appbox/logs' % volumes,
         '-v', '%s/mysql:/home/appbox/mysql' % volumes, '-v', '%s/public_html:/home/appbox/public_html' % volumes,
         '-v', '%s:/usr/local/bin/curl:ro' % shim, '-v', '%s/cb:/gate-cb' % volumes,
         '-v', '%s:/etc/dpkg/dpkg.cfg.d/zz-release-gate:ro' % dpkg,
         '-e', 'USERNAME=' + admin_user, '-e', 'PASSWORD=' + admin_password,
         '-e', 'FIRSTNAME=Gate', '-e', 'LASTNAME=Release', '-e', 'EMAIL=gate@example.com',
         '-e', 'URL=', '-e', 'INSTANCE_ID=' + INSTANCE_ID] + extra + [ref])
    containers.append(name)
    return name


def remove(name):
    run(['docker', 'stop', '-t', '60', name], check=False, timeout=180)
    run(['docker', 'rm', '-f', '-v', name], check=False, timeout=180)
    if name in containers:
        containers.remove(name)


def callbacks(volumes):
    path = volumes / 'cb' / 'callbacks'
    return path.read_text().splitlines() if path.exists() else []


def running(name):
    return out(['docker', 'inspect', '-f', '{{.State.Running}}', name]).strip() == 'true'


def sh(name, script, data=None, check=True, timeout=300):
    args = ['docker', 'exec'] + (['-i'] if data is not None else []) + [name, 'bash', '-c', script]
    return run(args, data=data, check=check, timeout=timeout)


def port(name):
    binding = out(['docker', 'port', name, '80/tcp']).strip().splitlines()[0]
    return int(binding.rsplit(':', 1)[1])


argv_snapshots = {}


def snapshot_processes(name):
    p = sh(name, 'for d in /proc/[0-9]*; do tr "\\0" " " < $d/cmdline 2>/dev/null; echo; done', check=False)
    argv_snapshots.setdefault(name, set()).update(p.stdout.decode(errors='replace').splitlines())


def wait_ready(name, volumes, expected_callbacks):
    deadline = time.time() + READY_TIMEOUT
    while time.time() < deadline:
        if not running(name):
            raise AssertionError(name + ' stopped while starting: ' + redact(
                out(['docker', 'logs', '--tail', '40', name], check=False))[-2500:])
        snapshot_processes(name)
        if len(callbacks(volumes)) >= expected_callbacks and sh(
                name, 'test -f /etc/installer_completed_mautic && '
                      'mysqladmin --no-defaults --socket=/run/mysqld/mysqld.sock ping', check=False).returncode == 0:
            try:
                status, _, body = web(name, 'GET', '/s/login')
                if status == 200 and '_csrf_token' in body:
                    return
            except OSError:
                pass
        time.sleep(3)
    raise AssertionError(name + ' was not ready after %d s' % READY_TIMEOUT)


def web(name, method, path, form=None, cookies=None):
    connection = http.client.HTTPConnection('127.0.0.1', port(name), timeout=120)
    headers = {'Host': name + '.example.test'}
    if cookies:
        headers['Cookie'] = '; '.join('%s=%s' % kv for kv in cookies.items())
    body = None
    if form is not None:
        body = urllib.parse.urlencode(form)
        headers['Content-Type'] = 'application/x-www-form-urlencoded'
    connection.request(method, path, body=body, headers=headers)
    response = connection.getresponse()
    text = response.read().decode(errors='replace')
    if cookies is not None:
        for header, value in response.getheaders():
            if header.lower() == 'set-cookie':
                pair = value.split(';', 1)[0]
                key, _, val = pair.partition('=')
                cookies[key.strip()] = val.strip()
    connection.close()
    return response.status, response.getheader('Location') or '', text


def login(name, password):
    cookies = {}
    status, _, body = web(name, 'GET', '/s/login', cookies=cookies)
    expect(status == 200, 'login page returned HTTP %s' % status)
    token = re.search(r'name="_csrf_token"\s+value="([^"]+)"', body)
    expect(token, 'no CSRF token on the login page')
    status, location, _ = web(name, 'POST', '/s/login_check', cookies=cookies, form={
        '_username': admin_user, '_password': password, '_csrf_token': token.group(1)})
    expect(status in (301, 302, 303), 'login returned HTTP %s' % status)
    path = urllib.parse.urlsplit(location).path
    # The first login of a new admin redirects the dashboard to itself once
    # while Mautic creates the default widgets.
    for _ in range(5):
        if path.endswith('/s/login'):
            return False
        status, location, body = web(name, 'GET', path, cookies=cookies)
        if status not in (301, 302, 303):
            return status == 200 and path == '/s/dashboard' and 'login_check' not in body
        path = urllib.parse.urlsplit(location).path
    return False


def check_login(name):
    expect(login(name, admin_password), 'the admin cannot log in')
    expect(not login(name, 'wrong-' + admin_password), 'a wrong admin password was accepted')


def listeners(name):
    text = out(['docker', 'exec', name, 'ss', '-ltnH'])
    found = {}
    for line in text.splitlines():
        local = line.split()[3]
        address, _, number = local.rpartition(':')
        found.setdefault(number, set()).add(address)
    return found


def reachable_from_other_container(name, tcp_port):
    address = out(['docker', 'inspect', '-f', '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}',
                   name]).strip()
    expect(re.fullmatch(r'\d+\.\d+\.\d+\.\d+', address), 'no container address')
    probe = run(['docker', 'run', '--rm', '--label', 'appbox.release-gate=' + run_id, '--entrypoint', 'bash',
                 CURRENT, '-c', 'timeout 5 bash -c "</dev/tcp/%s/%d"' % (address, tcp_port)],
                check=False, timeout=120)
    return probe.returncode == 0


def mysql_users(name, legacy=False):
    query = "SELECT CONCAT(user, '@', host) FROM mysql.user ORDER BY 1"
    if legacy:
        script = 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot -N -e "%s"' % query
    else:
        script = 'mysql --defaults-file=%s -N -e "%s"' % (CLIENT_CNF, query)
    return set(out(['docker', 'exec', name, 'bash', '-c', script]).split())


def read_secrets(name):
    cnf = out(['docker', 'exec', name, 'cat', CLIENT_CNF])
    match = re.search(r'^password="([^"]*)"$', cnf, re.M)
    expect(match, 'client.cnf has no password line')
    local = out(['docker', 'exec', name, 'runuser', '-u', 'appbox', '--', 'php', '-d', 'display_errors=stderr',
                 '-d', 'display_startup_errors=0', '-r',
                 '$parameters = []; include "%s"; echo "\\n@@JSON@@", json_encode($parameters);' % LOCAL_PHP])
    params = json.loads(local.rsplit('@@JSON@@', 1)[1])
    return match.group(1), params


def check_no_leaks(name, values, check_admin_password=True):
    values = {v for v in values if v}
    patterns = set(values) | ({admin_password} if check_admin_password else set())
    logs = run(['docker', 'logs', name], check=False)
    log_text = logs.stdout.decode(errors='replace') + logs.stderr.decode(errors='replace')
    for value in patterns:
        expect(value not in log_text, 'a password is in the container log')
    snapshot_processes(name)
    for line in argv_snapshots.get(name, ()):
        for value in values:
            expect(value not in line, 'a database password is in a process command line')
    environ = sh(name, 'for d in /proc/[0-9]*; do tr "\\0" "\\n" < $d/environ 2>/dev/null; done',
                 check=False).stdout.decode(errors='replace')
    for value in values:
        expect(value not in environ, 'a database password is in a process environment')
    crontab = out(['docker', 'exec', name, 'crontab', '-l'])
    expect('--defaults-file=' + CLIENT_CNF in crontab, 'the backup job does not use the client file')
    found = sh(name, 'grep -rlsF -D skip -f /dev/stdin /etc /var/log /var/spool /root /tmp /run /home/appbox/logs; true',
               data='\n'.join(values).encode() + b'\n').stdout.decode().split()
    expect(not found, 'a database password is stored in %s' % ', '.join(found))
    log('PASS %s: no database password in the log, process arguments or environment, crontab, '
        '/etc, /var/log, /var/spool, /root, /tmp, /run or the app logs' % name.rsplit('-', 1)[1])


def check_hardened(name, label):
    ports = listeners(name)
    expect(ports.get('3306') == {'127.0.0.1'}, '%s: MySQL listens on %s' % (label, ports.get('3306')))
    expect(ports.get('33060', {'127.0.0.1'}) == {'127.0.0.1'}, '%s: MySQL X listens on %s' % (label, ports.get('33060')))
    expect(not reachable_from_other_container(name, 3306), '%s: another container can connect to 3306' % label)
    users = mysql_users(name)
    expect('root@localhost' in users and not any(u.startswith('root@') and u != 'root@localhost' for u in users),
           '%s: root accounts are %s' % (label, sorted(u for u in users if u.startswith('root@'))))
    expect(not any(u.endswith('@%') for u in users), '%s: accounts with remote login: %s' % (label, sorted(users)))
    refused = run(['docker', 'exec', name, 'mysql', '--no-defaults', '--protocol=socket',
                   '--socket=/run/mysqld/mysqld.sock', '-uroot', '--skip-password',
                   '-e', 'SELECT 1'], check=False)
    expect(refused.returncode != 0 and b'Access denied' in refused.stderr,
           '%s: MySQL root accepts an empty password' % label)
    tcp = out(['docker', 'exec', name, 'mysql', '--defaults-file=' + CLIENT_CNF, '--protocol=tcp',
               '-h', '127.0.0.1', '-N', '-e', 'SELECT CURRENT_USER()']).strip()
    expect(tcp == 'root@localhost', '%s: TCP login over 127.0.0.1 maps to %s' % (label, tcp))
    mode = out(['docker', 'exec', name, 'stat', '-c', '%a', CLIENT_CNF]).strip()
    expect(mode == '600', '%s: client.cnf has mode %s' % (label, mode))
    log('PASS %s: MySQL only on 127.0.0.1 (3306, 33060), unreachable from another container, '
        'root only @localhost, no remote accounts, empty password refused, client.cnf 0600' % label)


def scenario_current_fresh():
    volumes = storage('upgrade')
    name = launch('current', CURRENT, volumes)
    wait_ready(name, volumes, 1)
    check_login(name)
    ports = listeners(name)
    users = mysql_users(name, legacy=True)
    open_port = reachable_from_other_container(name, 3306)
    expect('0.0.0.0' in ports.get('3306', set()) and 'root@%' in users and open_port,
           'the negative control did not reproduce the issue on 5.2.3-1')
    logs = run(['docker', 'logs', name], check=False)
    log('PASS 5.2.3-1 fresh install (negative control): login works; MySQL on %s, root@%% present, '
        'reachable from another container: %s; database password in the container log: %s' % (
            sorted(ports['3306']), open_port,
            old_password in (logs.stdout + logs.stderr).decode(errors='replace')))
    sh(name, 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot mautic -e '
             '"CREATE TABLE appbox_gate_marker (v VARCHAR(64)); INSERT INTO appbox_gate_marker VALUES (\'%s\');"'
       % run_id)
    users_before = out(['docker', 'exec', name, 'bash', '-c',
                        'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot -N mautic -e "SELECT COUNT(*) FROM users"']).strip()
    expect(users_before == '1', '5.2.3-1 install has %s Mautic users' % users_before)
    remove(name)
    return volumes, users_before


def scenario_upgrade(volumes, users_before):
    name = launch('upgrade', image, volumes)
    wait_ready(name, volumes, 2)
    check_login(name)
    check_hardened(name, 'upgrade')
    password, params = read_secrets(name)
    expect(password == old_password, 'upgrade: the existing database password was changed')
    expect(params.get('db_password') == old_password and params.get('db_user') == 'root',
           'upgrade: Mautic config no longer has the existing login')
    marker = out(['docker', 'exec', name, 'mysql', '--defaults-file=' + CLIENT_CNF, '-N', 'mautic', '-e',
                  'SELECT v FROM appbox_gate_marker']).strip()
    expect(marker == run_id, 'upgrade: data written before the upgrade is missing')
    users = out(['docker', 'exec', name, 'mysql', '--defaults-file=' + CLIENT_CNF, '-N', 'mautic', '-e',
                 'SELECT COUNT(*) FROM users']).strip()
    expect(users == users_before, 'upgrade: Mautic users changed')
    log('PASS upgrade from 5.2.3-1 with the same volumes: admin login works, data kept, '
        'existing database password kept in MySQL and Mautic config')
    check_no_leaks(name, {old_password})
    run(['docker', 'restart', '-t', '60', name], timeout=300)
    wait_ready(name, volumes, 2)
    check_login(name)
    check_hardened(name, 'upgrade-restart')
    check_no_leaks(name, {old_password})
    remove(name)


def scenario_fresh():
    volumes = storage('fresh')
    name = launch('fresh', image, volumes)
    wait_ready(name, volumes, 1)
    expect(len(callbacks(volumes)) == 1 and callbacks(volumes)[0].endswith('/' + INSTANCE_ID),
           'fresh: unexpected install callbacks')
    check_login(name)
    check_hardened(name, 'fresh')
    password, params = read_secrets(name)
    secret_values.add(password)
    expect(re.fullmatch(r'[A-Za-z0-9]{32}', password), 'fresh: the database password is not 32 random characters')
    expect(password != old_password, 'fresh: the shared database password was used')
    expect(params.get('db_password') == password and params.get('db_user') == 'root'
           and params.get('db_host') == 'localhost' and params.get('site_url'),
           'fresh: Mautic config does not use the stored database password')
    local_mode = out(['docker', 'exec', name, 'stat', '-c', '%U', LOCAL_PHP]).strip()
    expect(local_mode == 'appbox', 'fresh: local.php is not owned by appbox')
    log('PASS fresh install: login works, install callback sent once, random 32-character database '
        'password stored in client.cnf and Mautic config, not the shared one')
    check_no_leaks(name, {password, old_password})
    run(['docker', 'restart', '-t', '60', name], timeout=300)
    wait_ready(name, volumes, 1)
    check_login(name)
    check_hardened(name, 'fresh-restart')
    check_no_leaks(name, {password, old_password})
    # Fail closed: with MySQL root's password removed, the start-up script that
    # runs when the container is created must refuse to continue. Re-creating
    # the container would repeat the slow first-start package install, so run
    # the image's /scripts/mysql.sh in place, as /etc/my_init.d/20_installer.sh
    # does, after stopping the supervised MySQL.
    sh(name, "mysql --defaults-file=%s -e \"ALTER USER 'root'@'localhost' IDENTIFIED BY '';\" && rm -f %s"
       % (CLIENT_CNF, CLIENT_CNF))
    sh(name, 'sv -w 180 stop mysql >/dev/null; mkdir -p /sources && cp /home/appbox/config/mysql/mysqld.cnf /sources/')
    attempt = sh(name, '/bin/bash /scripts/mysql.sh', check=False, timeout=3600)
    text = (attempt.stdout + attempt.stderr).decode(errors='replace')
    expect(attempt.returncode != 0 and 'MySQL root has no password on an installed Mautic' in text,
           'empty-password: mysql.sh did not refuse to continue (exit %d)' % attempt.returncode)
    expect(not sh(name, 'test -s %s' % CLIENT_CNF, check=False).returncode == 0,
           'empty-password: mysql.sh stored credentials')
    log('PASS fail closed: on an installed Mautic whose MySQL root has no password, '
        'the start-up script stops (exit %d) instead of continuing' % attempt.returncode)
    remove(name)


def cleanup():
    for name in list(containers):
        remove(name)
    for name in out(['docker', 'ps', '-aq', '--filter', 'label=appbox.release-gate=' + run_id],
                    check=False).split():
        run(['docker', 'rm', '-f', '-v', name], check=False)
    if work.exists():
        # Containers wrote root-owned files into the volumes.
        run(['docker', 'run', '--rm', '--network', 'none', '-v', '%s:/w' % work, '--entrypoint', 'sh',
             CURRENT, '-c', 'rm -rf /w/* /w/.[!.]* 2>/dev/null; true'], check=False, timeout=600)
        shutil.rmtree(work, ignore_errors=True)


try:
    log('== Gate: %s (run %s)' % (image, run_id))
    registry_absent()
    if run(['docker', 'image', 'inspect', CURRENT], check=False).returncode:
        run(['docker', 'pull', '-q', '--platform', 'linux/amd64', CURRENT], timeout=1800)
    current_config = json.loads(out(['docker', 'image', 'inspect', CURRENT]))[0]['Config']['Env']
    old_password = dict(e.split('=', 1) for e in current_config)['MYSQL_ROOT_PASSWORD']
    expect(old_password, 'cannot read the shared password of 5.2.3-1')
    secret_values.add(old_password)
    aio = int(Path('/proc/sys/fs/aio-nr').read_text())
    aio_max = int(Path('/proc/sys/fs/aio-max-nr').read_text())
    expect(aio_max - aio > 20000, 'not enough free AIO contexts for a MySQL container (%d of %d used)' % (aio, aio_max))
    check_image(old_password)
    volumes, users_before = scenario_current_fresh()
    scenario_upgrade(volumes, users_before)
    scenario_fresh()
    registry_absent()
    log('PASS: ' + image)
except Exception as error:  # noqa: BLE001 - report every failure the same way
    log('FAIL: ' + redact(str(error)))
    sys.exit(1)
finally:
    cleanup()
