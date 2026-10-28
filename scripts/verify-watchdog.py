"""Exercise the built watchdog against owned disposable processes; never target real VS Code."""
import ctypes, json, os, pathlib, shutil, subprocess, tempfile, time, uuid
root = pathlib.Path(__file__).resolve().parents[1]
app = pathlib.Path(os.environ.get('CCGUARD_TEST_APP', root / 'dist/CC登录器.app/Contents/MacOS/CCGuard'))
base = root / '.build/IntegrationFixtures'
base.mkdir(parents=True, exist_ok=True)
fixture_source=base/'fixture.c'
fixture_source.write_text('#include <unistd.h>\nint main(void) { sleep(120); return 0; }\n')
fixture_binary=base/'FixtureSleep'
subprocess.run(['/usr/bin/cc',str(fixture_source),'-o',str(fixture_binary)],check=True)
results = []
# Cross-process leases must share the macOS uptime epoch. Some Python runtimes
# expose a process-relative monotonic clock, which cannot be compared to Swift's uptime.
libsystem=ctypes.CDLL('/usr/lib/libSystem.B.dylib')
libsystem.mach_absolute_time.restype=ctypes.c_uint64
class Timebase(ctypes.Structure):
    _fields_=[('numer',ctypes.c_uint32),('denom',ctypes.c_uint32)]
timebase=Timebase();libsystem.mach_timebase_info(ctypes.byref(timebase))
def uptime():return libsystem.mach_absolute_time()*timebase.numer/timebase.denom/1_000_000_000

def wait_for(predicate, timeout=7):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate(): return
        time.sleep(.05)
    raise AssertionError('timed out')

for mode in ([os.environ['CCGUARD_TEST_SCENARIO']] if os.environ.get('CCGUARD_TEST_SCENARIO') else ['parent_exit', 'stale_heartbeat', 'wrong_nonce', 'explicit_disarm', 'symlink_path', 'explicit_revocation']):
    print('Testing',mode,flush=True)
    folder = pathlib.Path(tempfile.mkdtemp(prefix=mode+'-', dir=base))
    fixture = folder/'CCGuardFixture.app/Contents/MacOS/FixtureSleep'
    fixture.parent.mkdir(parents=True)
    shutil.copyfile(fixture_binary, fixture)
    fixture.chmod(0o755)
    processes = []
    try:
        parent = subprocess.Popen(['/bin/sleep', '60']); processes.append(parent)
        launch_path=fixture
        if mode=='symlink_path':
            launch_path=folder/'LaunchAlias';launch_path.symlink_to(fixture)
        child = subprocess.Popen([str(launch_path), '60']); processes.append(child)
        time.sleep(.35)
        assert child.poll() is None, 'fixture failed before watchdog was started'
        unrelated = subprocess.Popen(['/bin/sleep', '60']); processes.append(unrelated)
        nonce = str(uuid.uuid4())
        def write_lease(armed=True):
            lease = {'nonce': nonce if mode != 'wrong_nonce' else 'wrong', 'parentPID':parent.pid,
                     'armed':armed,'heartbeat':uptime()}
            tmp = folder/'lease.tmp';tmp.write_text(json.dumps(lease));tmp.replace(folder/'lease.json')
        write_lease()
        worker = subprocess.Popen([str(app),'--watchdog-fixture',str(parent.pid),str(folder),nonce,str(fixture.parents[2])]);processes.append(worker)
        def heartbeat():
            try:return json.loads((folder/'worker.json').read_text())
            except (OSError, ValueError):return {}
        wait_for(lambda:heartbeat().get('nonce') == nonce)
        # A freshly signed macOS executable may need several seconds for its first launch.
        # Renew the fixture lease after startup, before testing its actual expiry behavior.
        write_lease()
        if mode != 'wrong_nonce':wait_for(lambda:heartbeat().get('armed') is True)
        assert child.poll() is None, 'fixture terminated before failure'
        start = time.monotonic()
        if mode == 'explicit_disarm':
            write_lease(False);wait_for(lambda:heartbeat().get('armed') is False)
            parent.terminate();parent.wait();worker.wait(timeout=4)
            assert child.poll() is None, ('fixture unexpectedly exited', mode, child.returncode, time.monotonic()-start)
        elif mode == 'wrong_nonce':
            assert heartbeat()['armed'] is False
            parent.terminate();parent.wait();worker.wait(timeout=4)
            assert child.poll() is None, ('fixture unexpectedly exited', mode, child.returncode, time.monotonic()-start)
        else:
            if mode in ('parent_exit','symlink_path'):parent.terminate();parent.wait()
            if mode=='explicit_revocation':(folder/'stop-request').write_text(nonce)
            child.wait(timeout=8);worker.wait(timeout=8)
            assert child.returncode == -9, child.returncode
        elapsed = round(time.monotonic()-start,3)
        assert unrelated.poll() is None, 'unrelated process was terminated'
        results.append({'scenario':mode,'passed':True,'elapsedSeconds':elapsed,'unrelatedProcessPreserved':True})
    finally:
        if (folder/'watchdog-error.json').exists():print((folder/'watchdog-error.json').read_text())
        for p in processes:
            if p.poll() is None:p.terminate()
        for p in processes:
            try:p.wait(timeout=3)
            except subprocess.TimeoutExpired:p.kill();p.wait()
        shutil.rmtree(folder)
report={'target':'owned disposable CCGuardFixture.app only','realVSCodeTouched':False,'results':results}
(root/'Evidence').mkdir(exist_ok=True)
(root/'Evidence/独立守护验证.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
print(json.dumps(report,ensure_ascii=False,indent=2))
