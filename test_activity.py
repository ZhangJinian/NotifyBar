#!/usr/bin/env python3
"""Real monitor + isolated fake desktop IPC; never touches the user's Codex state."""
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import time


def frame(connection, message):
    data = json.dumps(message).encode()
    connection.sendall(struct.pack('<I', len(data)) + data)


def receive(connection):
    def exact(size):
        result = b''
        while len(result) < size:
            chunk = connection.recv(size - len(result))
            if not chunk:
                raise EOFError('monitor disconnected')
            result += chunk
        return result
    return json.loads(exact(struct.unpack('<I', exact(4))[0]))


root = Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(prefix='mytouchbar-test-', dir='/tmp') as directory:
    home = Path(directory)
    (home / 'ipc').mkdir()
    thread = '00000000-0000-4000-8000-000000000001'
    def unread(enabled):
        state = {'electron-persisted-atom-state': {
            'thread-client-id-v1:local%3A' + thread: 'test',
            'unread-thread-ids-by-host-v1': {'local': [thread] if enabled else []}}}
        temporary = home / 'state.tmp'
        temporary.write_text(json.dumps(state))
        temporary.replace(home / '.codex-global-state.json')
    unread(False)
    with socket.socket(socket.AF_UNIX) as server:
        server.bind(str(home / 'ipc/ipc.sock'))
        server.listen(1)
        server.settimeout(10)
        process = subprocess.Popen([str(root / 'build/mytouchbar.app/Contents/MacOS/mytouchbar'), '--activity-probe'],
            env={**os.environ, 'CODEX_HOME': str(home)}, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            connection, _ = server.accept()
            with connection:
                connection.settimeout(10)
                request = receive(connection)
                frame(connection, {'type': 'response', 'method': 'initialize', 'requestId': request['requestId'],
                    'resultType': 'success', 'result': {'clientId': 'test-monitor'}})
                assert receive(connection)['method'] == 'thread-stream-following-changed'
                def snapshot(revision, status):
                    frame(connection, {'type': 'broadcast', 'method': 'thread-stream-state-changed', 'version': 11,
                        'sourceClientId': 'test-owner', 'params': {'hostId': 'local', 'conversationId': thread,
                        'change': {'type': 'snapshot', 'revision': revision,
                        'conversationState': {'threadRuntimeStatus': {'type': status}}}}})
                snapshot(1, 'active')
                time.sleep(1)
                unread(True)
                time.sleep(2)
                unread(False)
                time.sleep(2)
                snapshot(2, 'idle')
                output, errors = process.communicate(timeout=12)
                assert process.returncode == 0, errors
                assert output.splitlines() == ['Activity: running', 'Activity: unread', 'Activity: running', 'Activity: idle'], output
                print('PASS: running → unread priority → read clears red → completed clears blue')
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=5)
