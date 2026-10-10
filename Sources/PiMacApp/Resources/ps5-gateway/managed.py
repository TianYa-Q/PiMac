"""App-owned privileged session. Executed as an isolated, inline code snapshot."""
import json
import os
import re
import shutil
import stat
import time


def lease_alive(path, pid, uid):
    try:
        os.kill(pid, 0)
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            info = os.fstat(descriptor)
            return (stat.S_ISREG(info.st_mode) and info.st_uid == uid
                    and 0 <= time.time() - info.st_mtime < 12)
        finally:
            os.close(descriptor)
    except OSError:
        return False


def publish(folder, phase, detail='', identity=None):
    data = {'phase': phase, 'detail': detail, 'timestamp': time.time()}
    if identity:
        data['tun'] = identity[1]
    temporary = folder + '/status.next'
    with open(temporary, 'w') as output:
        json.dump(data, output)
    os.chmod(temporary, 0o644)
    os.replace(temporary, folder + '/status.json')


def managed_session(alive, emit, check=check_tun, read=read_parameter,
                    session_factory=Session, sleep=time.sleep):
    session = session_factory()
    error = None
    try:
        if not alive():
            raise RuntimeError('App session expired before startup')
        with exclusive_session():
            try:
                identity = check()
                if not alive():
                    raise RuntimeError('App session expired during startup')
                session.start()
                while alive():
                    if check() != identity:
                        raise RuntimeError('FlClashCore or TUN changed')
                    if read(FORWARD) != '1' or read(REDIRECT) != '0':
                        raise RuntimeError('Network settings changed externally')
                    emit('active', '', identity)
                    sleep(1)
            finally:
                # Failure to publish status must never prevent restoration.
                try:
                    emit('stopping', 'Restoring network settings')
                finally:
                    session.stop()
    except Exception as failure:
        error = str(failure)
    emit('error' if error else 'stopped', error or '')


def managed_main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--id', required=True)
    parser.add_argument('--lease', required=True)
    parser.add_argument('--pid', type=int, required=True)
    parser.add_argument('--uid', type=int, required=True)
    args = parser.parse_args()
    if not re.fullmatch(r'[a-f0-9-]{36}', args.id) or args.pid <= 1 or args.uid <= 0:
        raise RuntimeError('Invalid app session identity')
    if os.geteuid() != 0:
        raise RuntimeError('Administrator authorization required')
    folder = '/private/var/run/pimac-ps5-' + args.id
    # An existing directory (including symlinks) is never reused or written through.
    os.mkdir(folder, 0o755)
    os.chmod(folder, 0o755)
    signal.signal(signal.SIGTERM, terminate)
    signal.signal(signal.SIGHUP, terminate)
    emit = lambda phase, detail='', identity=None: publish(folder, phase, detail, identity)
    try:
        emit('starting')
        managed_session(lambda: lease_alive(args.lease, args.pid, args.uid), emit)
    except BaseException as error:
        # managed_session's finally restores parameters even on a termination signal.
        emit('error', str(error) or 'Session interrupted; inspect network settings')
    finally:
        # Keep the final result available long enough for the UI to acknowledge it.
        try:
            time.sleep(30)
        finally:
            shutil.rmtree(folder)


managed_main()
