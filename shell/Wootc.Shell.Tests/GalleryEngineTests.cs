using System.Text.RegularExpressions;
using System.Xml.Linq;
using Wootc.Shell.Core;
using Wootc.Shell.Engine;
using Wootc.Shell.Gallery;
using Xunit;

namespace Wootc.Shell.Tests;

// The screen gallery's fixture engine: each scene reaches its screen from
// recorded engine answers, nothing that would change a PC can run, and no
// shipped build contains it.
public sealed class GalleryEngineTests
{
    private static readonly string Fixtures = Path.Combine(AppContext.BaseDirectory, "Fixtures");
    private static readonly Branding Brand = new() { ProductName = "wootc", Name = "TunaOS" };

    private static async Task<GallerySessionView> Open(string scene, bool install = false)
    {
        var connector = new GalleryConnector(Fixtures, scene, TimeSpan.FromMilliseconds(1), TimeSpan.FromMilliseconds(1));
        var attempt = await connector.ConnectAsync(new ConnectRequest(Guid.NewGuid().ToString("N"), install), CancellationToken.None);
        Assert.Equal(ConnectionOutcome.Connected, attempt.Outcome);
        Assert.Equal(GalleryConnector.BrandId, connector.AuthenticatedBrandId);
        return new(connector, attempt.Session!);
    }

    private sealed record GallerySessionView(GalleryConnector Connector, IEngineSession Session);

    [Theory]
    [InlineData(GalleryScenes.Fresh, StartupRoute.Assessment)]
    [InlineData(GalleryScenes.Interrupted, StartupRoute.Interrupted)]
    [InlineData(GalleryScenes.Manage, StartupRoute.Manage)]
    [InlineData(GalleryScenes.Recovery, StartupRoute.Recovery)]
    public async Task EachSceneReachesItsScreenThroughTheStartupController(string scene, StartupRoute route)
    {
        var controller = new StartupController(Brand, new GalleryConnector(Fixtures, scene));
        await controller.RequestPermissionAsync();
        Assert.Equal(ConnectionState.Ready, controller.Connection);
        Assert.Equal(route, controller.Route);
        await controller.DisposeAsync();
    }

    [Fact]
    public async Task TheRecordedConfigurationMakesACompletePlanAndAnInstallOnlyReplaysItsStream()
    {
        var opened = await Open(GalleryScenes.Fresh, install: true);
        var snapshot = await ((IConfigurationEngineSession)opened.Session).ReadConfigurationAsync(CancellationToken.None);
        var form = new ConsumerConfiguration(snapshot.BrandId);
        form.ApplyCatalogue(ConfigurationProjection.ToCatalogue(snapshot));
        form.SelectImage(form.Images.First(image => image.Admitted).Id);
        form.SelectStorage(snapshot.Storage[0].Id);
        form.Username = "gallery_user"; form.Password = form.PasswordConfirmation = "public gallery password";
        form.Hostname = "gallery-pc"; form.DiskSizeGb = 20; form.Encryption = "none";
        Assert.Equal("", form.FormProblem);
        var gate = new InstallGate(opened.Connector, snapshot.BrandId);
        await gate.PrepareAsync(form.CreateDraft());
        Assert.True(gate.CanInstall, gate.Reason);
        var finished = new TaskCompletionSource();
        gate.Changed += () => { if (gate.State == InstallGateState.Finished) finished.TrySetResult(); };
        await gate.ConfirmAsync(snapshot.Steps);
        await finished.Task.WaitAsync(TimeSpan.FromSeconds(10));
        Assert.True(gate.Progress!.Done);
        await Assert.ThrowsAsync<InvalidOperationException>(() => gate.RebootAsync());
        Assert.Equal(InstallGateState.Finished, gate.State);
    }

    [Fact]
    public async Task NothingThatChangesAPCRuns()
    {
        var session = (await Open(GalleryScenes.Manage, install: true)).Session;
        var maintenance = (IMaintenanceEngineSession)session;
        Assert.True((await maintenance.ReadUninstallInfoAsync(CancellationToken.None)).Found);
        Assert.True((await maintenance.InspectBootAsync(CancellationToken.None)).CanRepairBoot);
        var grant = await maintenance.PrepareMaintenanceAsync(new NativeMaintenancePlan { Action = MaintenanceActions.Uninstall, DeleteRootDisk = true }, CancellationToken.None);
        Assert.True(grant.DeleteRootDisk);
        await Assert.ThrowsAsync<InvalidOperationException>(() => maintenance.ConfirmMaintenanceAsync(grant, CancellationToken.None));
        var vm = (IVMEngineSession)session;
        Assert.Equal("stopped", (await vm.ReadVMStatusAsync(CancellationToken.None)).Phase);
        await Assert.ThrowsAsync<InvalidOperationException>(() => vm.PrepareVMActionAsync(new NativeVMPlan { Action = VMActions.Boot }, CancellationToken.None));
        await Assert.ThrowsAsync<InvalidOperationException>(() => vm.ConfirmVMActionAsync(new NativeVMGrant(), CancellationToken.None));
        var install = (IInstallEngineSession)session;
        await Assert.ThrowsAsync<InvalidOperationException>(() => install.CancelInstallAsync(CancellationToken.None));
        await Assert.ThrowsAsync<InvalidOperationException>(() => install.RebootAsync(CancellationToken.None));
        Assert.Throws<ArgumentException>(() => new GalleryConnector(Fixtures, "real-engine"));
    }

    // Only a build that sets NativeGallery references the gallery; no
    // workflow publishes a shipped preview with it.
    [Fact]
    public void ShippedBuildsNeverContainTheGallery()
    {
        var project = XDocument.Load(Path.Combine(Fixtures, "Wootc.Shell.csproj"));
        foreach (var reference in project.Descendants().Where(element => element.Attribute("Include")?.Value.Contains("Gallery", StringComparison.Ordinal) == true || element.Attribute("Include")?.Value.Contains("fixtures", StringComparison.Ordinal) == true))
            Assert.Equal("'$(NativeGallery)' == 'true'", reference.Parent!.Attribute("Condition")?.Value);
        string workflow = File.ReadAllText(Path.Combine(Fixtures, "winui-preview.yml"));
        var publishes = Regex.Matches(workflow, @"dotnet publish[^\n]*").Select(match => match.Value).ToArray();
        Assert.Contains(publishes, line => line.Contains("NativeGallery=true", StringComparison.Ordinal));
        foreach (string line in publishes.Where(line => line.Contains("NativeGallery", StringComparison.Ordinal)))
            Assert.Contains("out/winui-gallery", line);
        foreach (string line in publishes.Where(line => line.Contains("winui-preview", StringComparison.Ordinal) || line.Contains("branded-preview", StringComparison.Ordinal)))
            Assert.DoesNotContain("NativeGallery", line);
    }
}
