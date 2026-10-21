"""Run after compiling CornerProbe.swift with HotCorner.swift. Quit SoftLock first."""
import pathlib
import subprocess
import time

recovery = pathlib.Path.home() / 'Library/Application Support/SoftLock/hot-corner.json'
assert not recovery.exists(), 'Disable SoftLock hot corner before this test.'

def action():
    return int(subprocess.check_output(['defaults', 'read', 'com.apple.dock', 'wvous-br-corner']))

original = action()
subprocess.run(['build/corner-probe', '--stop'], check=True)
assert action() == original, 'Normal stop must restore the corner.'
process = subprocess.Popen(['build/corner-probe'], stdout=subprocess.PIPE, text=True)
try:
    assert process.stdout.readline().strip() == 'ready'
    assert action() == 0, 'Native corner must be suppressed while SoftLock owns it.'
    process.kill()
    process.wait()
    deadline = time.monotonic() + 8
    while (action() != original or recovery.exists()) and time.monotonic() < deadline:
        time.sleep(0.2)
    assert action() == original, 'Recovery must restore the original corner after a crash.'
    assert not recovery.exists(), 'Recovery state must be cleared.'
    print('Hot corner restored after normal exit and forced termination.')
finally:
    if process.poll() is None:
        process.kill()
        process.wait()
