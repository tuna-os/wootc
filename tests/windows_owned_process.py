"""Bounded Windows test process ownership. Never targets an unowned PID."""
import ctypes
from ctypes import wintypes as W
import os
from pathlib import Path
import subprocess
import threading
import time


class STARTUPINFO(ctypes.Structure):
    _fields_ = [("cb", W.DWORD), ("reserved", W.LPWSTR), ("desktop", W.LPWSTR), ("title", W.LPWSTR), ("x", W.DWORD), ("y", W.DWORD), ("xsize", W.DWORD), ("ysize", W.DWORD), ("xchars", W.DWORD), ("ychars", W.DWORD), ("fill", W.DWORD), ("flags", W.DWORD), ("show", W.WORD), ("reserved2size", W.WORD), ("reserved2", ctypes.POINTER(ctypes.c_byte)), ("stdin", W.HANDLE), ("stdout", W.HANDLE), ("stderr", W.HANDLE)]


class PROCESSINFO(ctypes.Structure):
    _fields_ = [("process", W.HANDLE), ("thread", W.HANDLE), ("pid", W.DWORD), ("tid", W.DWORD)]


class BASICLIMIT(ctypes.Structure):
    _fields_ = [("processTime", ctypes.c_longlong), ("jobTime", ctypes.c_longlong), ("flags", W.DWORD), ("minWorking", ctypes.c_size_t), ("maxWorking", ctypes.c_size_t), ("activeLimit", W.DWORD), ("affinity", ctypes.c_size_t), ("priority", W.DWORD), ("scheduling", W.DWORD)]


class IOCOUNTERS(ctypes.Structure):
    _fields_ = [(name, ctypes.c_ulonglong) for name in ("readOps", "writeOps", "otherOps", "readBytes", "writeBytes", "otherBytes")]


class EXTENDEDLIMIT(ctypes.Structure):
    _fields_ = [("basic", BASICLIMIT), ("io", IOCOUNTERS), ("processMemory", ctypes.c_size_t), ("jobMemory", ctypes.c_size_t), ("peakProcess", ctypes.c_size_t), ("peakJob", ctypes.c_size_t)]


class ACCOUNTING(ctypes.Structure):
    _fields_ = [(name, ctypes.c_longlong) for name in ("user", "kernel", "periodUser", "periodKernel")] + [(name, W.DWORD) for name in ("pageFaults", "totalProcesses", "activeProcesses", "terminatedProcesses")]


class OwnedProcessFailure(RuntimeError):
    def __init__(self, facts):
        super().__init__("Owned test process observation refused")
        self.facts = facts


def run_owned(arguments, cwd, output_prefix, timeout=120, limit=8*1024*1024):
    if os.name != "nt" or not 0 < timeout <= 120 or not 0 < limit <= 8*1024*1024:
        raise RuntimeError("Windows owned process bounds required")
    executable = Path(arguments[0])
    if not executable.is_absolute() or not executable.is_file():
        raise RuntimeError("Absolute executable identity required")
    import msvcrt
    k = ctypes.WinDLL("kernel32", use_last_error=True)
    specifications = {
        "CreateJobObjectW": ([ctypes.c_void_p, W.LPCWSTR], W.HANDLE),
        "SetInformationJobObject": ([W.HANDLE, ctypes.c_int, ctypes.c_void_p, W.DWORD], W.BOOL),
        "QueryInformationJobObject": ([W.HANDLE, ctypes.c_int, ctypes.c_void_p, W.DWORD, ctypes.POINTER(W.DWORD)], W.BOOL),
        "AssignProcessToJobObject": ([W.HANDLE, W.HANDLE], W.BOOL),
        "TerminateJobObject": ([W.HANDLE, W.UINT], W.BOOL),
        "CreateProcessW": ([W.LPCWSTR, W.LPWSTR, ctypes.c_void_p, ctypes.c_void_p, W.BOOL, W.DWORD, ctypes.c_void_p, W.LPCWSTR, ctypes.POINTER(STARTUPINFO), ctypes.POINTER(PROCESSINFO)], W.BOOL),
        "ResumeThread": ([W.HANDLE], W.DWORD),
        "WaitForSingleObject": ([W.HANDLE, W.DWORD], W.DWORD),
        "GetExitCodeProcess": ([W.HANDLE, ctypes.POINTER(W.DWORD)], W.BOOL),
        "TerminateProcess": ([W.HANDLE, W.UINT], W.BOOL),
        "CloseHandle": ([W.HANDLE], W.BOOL),
    }
    for name, (arguments_type, result_type) in specifications.items():
        function = getattr(k, name); function.argtypes = arguments_type; function.restype = result_type
    facts = {"started": False, "assignedBeforeResume": False, "parentExited": False, "jobDrained": False, "streamsDrained": False, "timeout": False, "overflow": False, "exitCode": None, "pid": None, "failureStage": None, "win32Error": None}
    def refused(stage):
        facts["failureStage"] = stage
        facts["win32Error"] = ctypes.get_last_error()
        return OwnedProcessFailure(facts)

    job = k.CreateJobObjectW(None, None)
    if not job:
        raise refused("create-job")
    handles = PROCESSINFO(); readers = []; writers = []; threads = []; overflow = threading.Event(); stream_error = threading.Event(); stdin = None
    started = time.monotonic()
    try:
        limits = EXTENDEDLIMIT(); limits.basic.flags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE; no breakaway.
        if not k.SetInformationJobObject(job, 9, ctypes.byref(limits), ctypes.sizeof(limits)):
            raise refused("set-job-limits")
        stdin = os.open(os.devnull, os.O_RDONLY); os.set_inheritable(stdin, True)
        for _ in range(2):
            read, write = os.pipe(); readers.append(read); writers.append(write); os.set_inheritable(write, True)
        startup = STARTUPINFO(); startup.cb = ctypes.sizeof(startup); startup.flags = 0x100
        startup.stdin = msvcrt.get_osfhandle(stdin); startup.stdout = msvcrt.get_osfhandle(writers[0]); startup.stderr = msvcrt.get_osfhandle(writers[1])
        environment = dict(os.environ, DOTNET_CLI_DO_NOT_USE_MSBUILD_SERVER="1", MSBUILDDISABLENODEREUSE="1")
        block = ctypes.create_unicode_buffer("\0".join(f"{name}={value}" for name, value in sorted(environment.items()))+"\0\0")
        command = ctypes.create_unicode_buffer(subprocess.list2cmdline(arguments))
        if not k.CreateProcessW(arguments[0], command, None, None, True, 0x4|0x400|0x08000000, ctypes.cast(block,ctypes.c_void_p), str(cwd), ctypes.byref(startup), ctypes.byref(handles)):
            raise refused("create-process")
        facts["started"] = True; facts["pid"] = handles.pid
        if not k.AssignProcessToJobObject(job, handles.process):
            # This exact owned process is still suspended: no descendant can have run.
            assignment_error = ctypes.get_last_error()
            k.TerminateProcess(handles.process, 1); k.WaitForSingleObject(handles.process, 5000)
            facts["parentExited"] = k.WaitForSingleObject(handles.process, 0) == 0
            facts["failureStage"] = "assign-job"; facts["win32Error"] = assignment_error
            raise OwnedProcessFailure(facts)
        facts["assignedBeforeResume"] = True
        for fd in writers: os.close(fd)
        writers.clear(); os.close(stdin); stdin = None

        def drain(fd, path):
            total = 0
            try:
                with os.fdopen(fd, "rb", buffering=0) as incoming, Path(path).open("wb") as raw:
                    while True:
                        chunk = incoming.read(65536)
                        if not chunk: break
                        allowed = min(len(chunk), max(0, limit-total))
                        raw.write(chunk[:allowed]); total += allowed
                        if allowed < len(chunk): overflow.set()
            except Exception:
                stream_error.set()
        for fd, stream in zip(readers, ("stdout", "stderr")):
            thread = threading.Thread(target=drain, args=(fd, str(output_prefix)+f".{stream}.raw"), daemon=True); thread.start(); threads.append(thread)
        readers.clear()
        if k.ResumeThread(handles.thread) == 0xffffffff:
            raise refused("resume-process")
        while k.WaitForSingleObject(handles.process, 50) == 258:
            if overflow.is_set() or stream_error.is_set() or time.monotonic()-started >= timeout:
                facts["timeout"] = time.monotonic()-started >= timeout
                break
        facts["overflow"] = overflow.is_set()
        if facts["timeout"] or facts["overflow"] or stream_error.is_set():
            if not k.TerminateJobObject(job, 1): raise refused("terminate-job")
        if k.WaitForSingleObject(handles.process, 5000) != 0:
            raise refused("wait-parent")
        facts["parentExited"] = True
        code = W.DWORD()
        if not k.GetExitCodeProcess(handles.process, ctypes.byref(code)): raise refused("read-exit")
        facts["exitCode"] = code.value
        drain_deadline = time.monotonic()+5
        while True:
            accounting = ACCOUNTING()
            if not k.QueryInformationJobObject(job, 1, ctypes.byref(accounting), ctypes.sizeof(accounting), None): raise refused("query-job")
            if accounting.activeProcesses == 0:
                facts["jobDrained"] = True; break
            if time.monotonic() >= drain_deadline:
                k.TerminateJobObject(job, 1)
                facts["failureStage"] = "drain-job"
                raise OwnedProcessFailure(facts)
            time.sleep(.02)
        for thread in threads: thread.join(2)
        facts["streamsDrained"] = all(not thread.is_alive() for thread in threads) and not stream_error.is_set()
        facts["overflow"] = overflow.is_set()
        if not facts["streamsDrained"]:
            facts["failureStage"] = "drain-streams"
            raise OwnedProcessFailure(facts)
        return facts
    finally:
        if handles.process and facts["assignedBeforeResume"] and not facts["jobDrained"]:
            k.TerminateJobObject(job, 1)
            end = time.monotonic()+5
            while time.monotonic() < end:
                accounting = ACCOUNTING()
                if k.QueryInformationJobObject(job, 1, ctypes.byref(accounting), ctypes.sizeof(accounting), None) and accounting.activeProcesses == 0:
                    facts["jobDrained"] = True; break
                time.sleep(.02)
            facts["parentExited"] = k.WaitForSingleObject(handles.process, 0) == 0
        for fd in writers+readers:
            os.close(fd)
        if stdin is not None: os.close(stdin)
        for handle in (handles.thread, handles.process, job):
            if handle: k.CloseHandle(handle)
        for thread in threads: thread.join(2)
        facts["streamsDrained"] = all(not thread.is_alive() for thread in threads) and not stream_error.is_set()
        facts["overflow"] = overflow.is_set()
        facts["elapsedMilliseconds"] = int((time.monotonic()-started)*1000)
