#!/usr/bin/env python3
"""Temporary IPv4 gateway session using an existing FlClash TUN."""
import argparse
import contextlib
import fcntl
import json
import os
import re
import signal
import subprocess
import sys
import time

SYSCTL = '/usr/sbin/sysctl'
ROUTE = '/sbin/route'
FORWARD = 'net.inet.ip.forwarding'
REDIRECT = 'net.inet.ip.redirect'
CORE = '/Applications/FlClash.app/Contents/MacOS/FlClashCore'
LOCK = '/var/run/flclash-ps5-gateway.lock'


def command(*args):
    result = subprocess.run(args, capture_output=True, text=True, timeout=5,
                            env={'PATH': '/usr/bin:/bin:/usr/sbin:/sbin',
                                 'LC_ALL': 'C'})
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or 'Command failed: ' + args[0])
    return result.stdout.strip()


def read_parameter(key):
    value = command(SYSCTL, '-n', key)
    if value not in ('0', '1'):
        raise RuntimeError('Unexpected sysctl value: ' + key)
    return value


def write_parameter(key, value):
    command(SYSCTL, '-w', key + '=' + value)


def route_interface(address):
    output = command(ROUTE, '-n', 'get', address)
    match = re.search(r'^\s*interface:\s*(\S+)\s*$', output, re.MULTILINE)
    if not match:
        raise RuntimeError('Cannot determine route for ' + address)
    return match.group(1)


def check_tun():
    processes = command('/bin/ps', '-axo', 'pid=,comm=')
    pids = []
    for line in processes.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) == 2 and fields[1] == CORE:
            pids.append(fields[0])
    if len(pids) != 1:
        raise RuntimeError('Exactly one installed FlClashCore must be running')
    interface = route_interface('1.1.1.1')
    if not re.fullmatch(r'utun\d+', interface):
        raise RuntimeError('Public IPv4 traffic is not routed through a TUN')
    if route_interface('198.18.0.2') != interface:
        raise RuntimeError('DNS test address and public traffic use different routes')
    addresses = command('/sbin/ifconfig', interface)
    if not re.search(r'\binet 198\.18\.0\.1\b', addresses):
        raise RuntimeError('TUN does not have the expected FlClash IPv4 address')
    return pids[0], interface


class Session:
    def __init__(self, read=read_parameter, write=write_parameter):
        self.read = read
        self.write = write
        self.original = {}
        self.applied = {REDIRECT: '0', FORWARD: '1'}

    def start(self):
        values = {key: self.read(key) for key in self.applied}
        if values[FORWARD] != '0':
            raise RuntimeError('IP forwarding is already enabled; refusing to take ownership')
        try:
            for key, value in self.applied.items():
                if values[key] == value:
                    continue
                self.original[key] = values[key]
                self.write(key, value)
        except Exception:
            self.stop()
            raise

    def stop(self):
        failures = []
        for key in reversed(tuple(self.original)):
            try:
                current = self.read(key)
                if current == self.applied[key]:
                    self.write(key, self.original[key])
                elif current != self.original[key]:
                    failures.append(key + ' changed externally; left untouched')
                del self.original[key]
            except Exception as error:
                failures.append(key + ': ' + str(error))
        if failures:
            raise RuntimeError('Restore needs attention: ' + '; '.join(failures))


@contextlib.contextmanager
def exclusive_session():
    flags = os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW
    descriptor = os.open(LOCK, flags, 0o600)
    try:
        stat = os.fstat(descriptor)
        if stat.st_uid != 0 or stat.st_mode & 0o022:
            raise RuntimeError('Gateway lock must be root-owned and not writable by others')
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError('Another gateway session is already running') from None
        yield
    finally:
        os.close(descriptor)


def terminate(signum, frame):
    raise KeyboardInterrupt


def inspect_environment():
    result = {'ready': False, 'detail': '', 'addresses': []}
    try:
        interfaces = command('/sbin/ifconfig')
        for block in re.split(r'(?m)(?=^[a-z][a-z0-9]*:)', interfaces):
            name = re.match(r'(en\d+):', block)
            if name and 'status: active' in block:
                for address in re.findall(r'\binet (\d+\.\d+\.\d+\.\d+)\b', block):
                    result['addresses'].append(name.group(1) + ': ' + address)
        identity = check_tun()
        result['tun'] = identity[1]
        if read_parameter(FORWARD) != '0':
            raise RuntimeError('IP forwarding is already enabled; refusing to take ownership')
        result['ready'] = True
    except Exception as error:
        result['detail'] = str(error)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', action='store_true',
                        help='Enable forwarding until Ctrl-C; requires sudo')
    parser.add_argument('--inspect-json', action='store_true')
    args = parser.parse_args()
    if args.inspect_json:
        print(json.dumps(inspect_environment()))
        return
    if sys.platform != 'darwin':
        raise RuntimeError('This tool supports macOS only')
    identity = check_tun()
    print('FlClashCore PID: %s; TUN: %s' % identity)
    print('IPv4 forwarding: ' + read_parameter(FORWARD))
    print('ICMP redirects: ' + read_parameter(REDIRECT))
    print('Check PS5 gateway = Mac LAN IPv4, DNS = 198.18.0.2, proxy = unused.')
    print('IPv4 only. Disable IPv6 for PS5 at the router to prevent bypass.')
    print('This is experimental routing, NOT a fail-closed VPN or kill switch.')
    if not args.run:
        print('Read-only check complete. No network changes made.')
        return
    if os.geteuid() != 0:
        raise RuntimeError('--run requires sudo')
    signal.signal(signal.SIGTERM, terminate)
    with exclusive_session():
        session = Session()
        try:
            session.start()
            print('Gateway session active. Keep this terminal open; Ctrl-C restores settings.',
                  flush=True)
            while True:
                time.sleep(1)
                if check_tun() != identity:
                    raise RuntimeError('FlClashCore or TUN changed; ending gateway session')
                if read_parameter(FORWARD) != '1' or read_parameter(REDIRECT) != '0':
                    raise RuntimeError('Network settings changed externally; ending session')
        finally:
            session.stop()
            print('Gateway session ended; owned system settings restored.', flush=True)


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        pass
    except Exception as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
