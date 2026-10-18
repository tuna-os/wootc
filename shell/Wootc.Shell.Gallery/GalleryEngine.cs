using System.Text.Json;
using System.Text.Json.Nodes;
using Wootc.Shell.Core;
using Wootc.Shell.Engine;

namespace Wootc.Shell.Gallery;

public static class GalleryScenes
{
    public const string Fresh = "fresh";
    public const string Interrupted = "interrupted";
    public const string Manage = "manage";
    public const string Recovery = "recovery";
    public static readonly string[] All = [Fresh, Interrupted, Manage, Recovery];
}

// The screen gallery's engine: recorded engine answers and event streams,
// served without an engine process, a pipe or administrator rights. It
// never installs, removes, repairs, restarts or runs a VM: the actions that
// would change this PC refuse, and a confirmed install only replays the
// engine's recorded install:progress stream.
public sealed class GalleryConnector : IBrandedEngineConnector
{
    public const string BrandId = "wootc";
    private readonly string fixtures;
    private readonly string scene;
    private readonly TimeSpan step;
    private readonly TimeSpan hold;

    public GalleryConnector(string fixtures, string scene, TimeSpan? step = null, TimeSpan? hold = null)
    {
        if (!GalleryScenes.All.Contains(scene)) throw new ArgumentException($"Unknown gallery scene {scene}", nameof(scene));
        this.fixtures = fixtures;
        this.scene = scene;
        this.step = step ?? TimeSpan.FromMilliseconds(200);
        this.hold = hold ?? TimeSpan.FromSeconds(20);
    }

    // The scene comes from WOOTC_NATIVE_GALLERY_SCENE; only a gallery build reads it.
    public static GalleryConnector FromEnvironment(string baseDirectory) =>
        new(Path.Combine(baseDirectory, "Fixtures"), Environment.GetEnvironmentVariable("WOOTC_NATIVE_GALLERY_SCENE") is { Length: > 0 } chosen ? chosen : GalleryScenes.Fresh);

    public string? AuthenticatedBrandId { get; private set; }

    public Task<ConnectionAttempt> ConnectAsync(ConnectRequest request, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        AuthenticatedBrandId = BrandId;
        return Task.FromResult(new ConnectionAttempt(ConnectionOutcome.Connected, new GallerySession(this, request)));
    }

    internal string Read(params string[] parts) => File.ReadAllText(Path.Combine([fixtures, .. parts]));

    internal JsonObject[] Results(string folder) => File.ReadAllLines(Path.Combine(fixtures, folder, "responses.ndjson"))
        .Select(line => JsonNode.Parse(line)!["response"]!["result"]!.AsObject()).ToArray();

    internal StartupSnapshot Startup()
    {
        var none = JsonSerializer.Deserialize<InstallRecoverySummary>(Read("install-recovery", "none.json"))!;
        return scene switch
        {
            GalleryScenes.Interrupted => new(new InstallStatus(), null, new LifecycleState(), JsonSerializer.Deserialize<InstallRecoverySummary>(Read("install-recovery", "interrupted.json"))),
            GalleryScenes.Manage => new(new InstallStatus { Existing = true }, null, new LifecycleState { State = "deployed" }, none),
            // No recorded verdict: the Recovery screen shows the legacy fallback words.
            GalleryScenes.Recovery => new(new InstallStatus { Existing = true }, null, new LifecycleState { State = "failed" }, none),
            _ => new(new InstallStatus(), null, new LifecycleState(), none),
        };
    }

    internal TimeSpan Step => step;
    internal TimeSpan Hold => hold;
}

internal sealed class GallerySession(GalleryConnector gallery, ConnectRequest request)
    : IConfigurationEngineSession, IInstallEngineSession, IMaintenanceEngineSession, IVMEngineSession
{
    private const string Intent = "fedcba9876543210fedcba9876543210";
    private readonly CancellationTokenSource closed = new();
    private bool finished;

    private static Exception Refused(string what) => new InvalidOperationException($"The screen gallery does not {what}; it has no engine.");

    public Task<StartupSnapshot> ReadStartupAsync(CancellationToken cancellationToken) => Task.FromResult(gallery.Startup());

    public Task<NativeConfigurationSnapshot> ReadConfigurationAsync(CancellationToken cancellationToken, Action<long>? requestFlushed = null)
    {
        requestFlushed?.Invoke(1);
        return Task.FromResult(JsonSerializer.Deserialize<NativeConfigurationSnapshot>(gallery.Read("native-gallery", "configuration.json"))!);
    }

    // Recorded: the smallest image's reserve, from the registry.
    public Task<ConfigurationInstallSpace> ReadInstallSpaceAsync(string imageRef, string storageDrive, CancellationToken cancellationToken) =>
        Task.FromResult(new ConfigurationInstallSpace(imageRef, storageDrive, ConsumerConfiguration.MinimumInstallReserveGb, "registry"));

    public event Action<ProgressEvent>? ProgressReceived;
    // The gallery runs no VM, so it raises no VM progress.
    public event Action<VMEvent>? VMProgressReceived { add { } remove { } }

    public Task<NativeInstallGrant> PrepareInstallAsync(InstallConfig plan, CancellationToken cancellationToken) =>
        Task.FromResult(new NativeInstallGrant
        {
            SchemaVersion = 1, Session = request.SessionId, BrandId = GalleryConnector.BrandId, IntentId = Intent, ImageRef = plan.ImageRef,
            StorageDrive = plan.StorageDrive, DiskSizeGB = plan.DiskSizeGB, Encryption = plan.Encryption.Length == 0 ? "none" : plan.Encryption,
        });

    // Replays the engine's recorded stream; the final event waits, so each
    // screen of the install can be seen.
    public Task ConfirmInstallAsync(NativeInstallGrant grant, CancellationToken cancellationToken)
    {
        var events = gallery.Read("install-progress", "success.ndjson").Split('\n', StringSplitOptions.RemoveEmptyEntries)
            .Select(line => JsonNode.Parse(line)!["params"]!.Deserialize<ProgressEvent>()!).ToArray();
        _ = Task.Run(async () =>
        {
            try
            {
                for (int index = 0; index < events.Length; index++)
                {
                    await Task.Delay(index == events.Length - 1 ? gallery.Hold : gallery.Step, closed.Token);
                    ProgressReceived?.Invoke(events[index]);
                }
                finished = true;
            }
            catch (OperationCanceledException) { }
        });
        return Task.CompletedTask;
    }

    public Task<InstallStatus> GetInstallStatusAsync(CancellationToken cancellationToken) => Task.FromResult(new InstallStatus { Done = finished });
    public Task CancelInstallAsync(CancellationToken cancellationToken) => Task.FromException(Refused("cancel an install"));
    public Task RebootAsync(CancellationToken cancellationToken) => Task.FromException(Refused("restart Windows"));

    public Task<UninstallInfo> ReadUninstallInfoAsync(CancellationToken cancellationToken) =>
        Task.FromResult(gallery.Results("native-maintenance")[0].Deserialize<UninstallInfo>()!);
    public Task<BootRepairReport> InspectBootAsync(CancellationToken cancellationToken) =>
        Task.FromResult(gallery.Results("native-maintenance")[2].Deserialize<BootRepairReport>()!);

    public Task<NativeMaintenanceGrant> PrepareMaintenanceAsync(NativeMaintenancePlan plan, CancellationToken cancellationToken)
    {
        var grant = gallery.Results("native-maintenance")[3].Deserialize<NativeMaintenanceGrant>()!;
        grant.Session = request.SessionId; grant.Action = plan.Action;
        grant.DeleteRootDisk = plan.DeleteRootDisk; grant.RemovePartition = plan.RemovePartition;
        return Task.FromResult(grant);
    }
    public Task ConfirmMaintenanceAsync(NativeMaintenanceGrant grant, CancellationToken cancellationToken) => Task.FromException(Refused("remove or repair anything"));

    public Task<NativeVMStatus> ReadVMStatusAsync(CancellationToken cancellationToken) =>
        Task.FromResult(gallery.Results("native-vm")[1].Deserialize<NativeVMStatus>()!);
    public Task<NativeVMGrant> PrepareVMActionAsync(NativeVMPlan plan, CancellationToken cancellationToken) => Task.FromException<NativeVMGrant>(Refused("run a Linux window"));
    public Task ConfirmVMActionAsync(NativeVMGrant grant, CancellationToken cancellationToken) => Task.FromException(Refused("run a Linux window"));

    public ValueTask DisposeAsync()
    {
        closed.Cancel();
        return ValueTask.CompletedTask;
    }
}
