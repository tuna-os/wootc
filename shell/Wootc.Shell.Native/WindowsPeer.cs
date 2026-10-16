using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace Wootc.Shell.Native;

internal sealed record WindowsPeer(string UserSid, uint SessionId, string ImagePath, bool Elevated)
{
    public static WindowsPeer Observe(Process process)
    {
        // Process.Handle is retained by the caller through authentication and
        // disconnect; recycling its numeric PID cannot substitute another peer.
        var handle = process.Handle;
        if (process.HasExited) throw new InvalidDataException("The engine process has exited");
        if (!OpenProcessToken(handle, 0x0008, out var token)) throw new Win32Exception();
        using (token)
        {
            using var identity = new WindowsIdentity(token.DangerousGetHandle());
            string sid = identity.User?.Value ?? throw new InvalidDataException("Actual process user is missing");
            if (!ProcessIdToSessionId((uint)process.Id, out uint session)) throw new Win32Exception();
            if (!GetTokenInformation(token, 12, out uint tokenSession, 4, out uint sessionSize) || sessionSize != 4 || tokenSession != session)
                throw new InvalidDataException("Process and token session identities differ");
            if (!GetTokenInformation(token, 20, out uint elevated, 4, out uint elevationSize) || elevationSize != 4) throw new Win32Exception();
            var path = new StringBuilder(32768);
            uint length = (uint)path.Capacity;
            if (!QueryFullProcessImageName(handle, 0, path, ref length)) throw new Win32Exception();
            if (process.HasExited) throw new InvalidDataException("The engine exited during identity observation");
            return new(sid, session, path.ToString(), elevated != 0);
        }
    }

    public static void VerifyPipeServer(SafePipeHandle pipe, Process engine, WindowsPeer source, string expectedPath)
    {
        if (!GetNamedPipeServerProcessId(pipe, out uint serverPid)) throw new Win32Exception();
        if (serverPid != (uint)engine.Id) throw new InvalidDataException("The pipe server is not the retained engine process");
        var observed = Observe(engine);
        if (!observed.Elevated || observed.UserSid != source.UserSid || observed.SessionId != source.SessionId ||
            !string.Equals(Path.GetFullPath(observed.ImagePath), Path.GetFullPath(expectedPath), StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("The engine process does not match this user session and protected package");
    }

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool OpenProcessToken(nint process, uint access, out SafeAccessTokenHandle token);
    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetTokenInformation(SafeAccessTokenHandle token, int informationClass, out uint information, uint length, out uint returnedLength);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ProcessIdToSessionId(uint process, out uint session);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool QueryFullProcessImageName(nint process, uint flags, StringBuilder path, ref uint size);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetNamedPipeServerProcessId(SafePipeHandle pipe, out uint process);
}
