using Wootc.Shell.Engine;

namespace Wootc.Shell.Core;

public static class VMActions
{
    public const string InstallRuntime = "install-runtime";
    public const string Prepare = "prepare";
    public const string Boot = "boot";
    public const string Stop = "stop";
    public const string ForceStop = "force-stop";
}

// The versioned VM contract of an install-purpose session. The status is a
// projection without paths or process identities. Every action that changes
// the VM needs its own engine grant, used once. The session that starts a VM
// owns it: closing that session stops the VM.
public interface IVMEngineSession : IEngineSession
{
    Task<NativeVMStatus> ReadVMStatusAsync(CancellationToken cancellationToken);
    Task<NativeVMGrant> PrepareVMActionAsync(NativeVMPlan plan, CancellationToken cancellationToken);
    Task ConfirmVMActionAsync(NativeVMGrant grant, CancellationToken cancellationToken);
    // vm:progress notifications of this session, validated, in order.
    event Action<VMEvent>? VMProgressReceived;
}
