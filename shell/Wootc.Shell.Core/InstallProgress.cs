using Wootc.Shell.Engine;

namespace Wootc.Shell.Core;

public enum InstallStepState { Pending, Active, Done, Error }
public sealed record InstallStepView(string Id, string Label, InstallStepState State);

// The progress view applies install:progress events the way the legacy
// frontend does (app/frontend/src/main.js): the newest step is current, and
// every catalogue step before a newly started one is complete. Labels come
// from the engine's step catalogue; matching uses step IDs only.
public sealed class InstallProgress
{
    public const string BitLockerStep = "Saving your BitLocker recovery key";
    public const string ArmStep = "Making Linux bootable on your machine";
    private readonly IReadOnlyList<StepDefinition> steps;
    private readonly HashSet<string> completed = new(StringComparer.Ordinal);
    public string Step { get; private set; } = "";
    public string Message { get; private set; } = "";
    public double Percent { get; private set; }
    public string? Error { get; private set; }
    public bool Done { get; private set; }

    public InstallProgress(IEnumerable<StepDefinition> catalogue)
    {
        var installer = (catalogue ?? throw new ArgumentNullException(nameof(catalogue))).Where(step => step.Owner == "installer").ToArray();
        if (installer.Length == 0 || installer.Any(step => string.IsNullOrEmpty(step.Id) || string.IsNullOrEmpty(step.Label)) ||
            installer.Select(step => step.Id).Distinct(StringComparer.Ordinal).Count() != installer.Length)
            throw new InvalidDataException("Installer step catalogue is invalid");
        steps = installer;
    }

    public void Apply(ProgressEvent update)
    {
        ArgumentNullException.ThrowIfNull(update);
        if (Done) return;
        Step = !string.IsNullOrEmpty(update.PhaseId) ? update.PhaseId : update.Step;
        Message = update.Message;
        Percent = double.IsFinite(update.Percent) ? Math.Clamp(update.Percent, 0, 100) : Percent;
        if (!string.IsNullOrEmpty(update.Error)) Error = update.Error;
        if (update.Done) { Done = true; return; }
        int index = IndexOf(Step);
        for (int earlier = 0; earlier < index; earlier++) completed.Add(steps[earlier].Id);
    }

    private int IndexOf(string id)
    {
        for (int index = 0; index < steps.Count; index++) if (steps[index].Id == id) return index;
        return -1;
    }

    public string StepLabel => steps.FirstOrDefault(step => step.Id == Step)?.Label ?? (Step.Length != 0 ? Step : "Starting…");

    // From the step that arms the one-time startup entry, "nothing changed"
    // is no longer true. The legacy screen says what is true at each point.
    public bool PastArm => completed.Contains(ArmStep) || (Step == ArmStep && Error is null);

    public IReadOnlyList<InstallStepView> Steps => steps.Select(step =>
    {
        bool active = Step == step.Id;
        var state = completed.Contains(step.Id) ? InstallStepState.Done
            : active && Error is null ? InstallStepState.Active
            : active ? InstallStepState.Error : InstallStepState.Pending;
        return new InstallStepView(step.Id, step.Label, state);
    }).ToArray();
}

// The legacy progress and done screens' own words
// (app/frontend/src/screens/progress.js and done.js), HTML removed.
// InstallProgressTextTests compares every line with those files.
public static class InstallProgressText
{
    public static string Title(Branding brand) => $"Installing {brand.Name}";
    public static string Subtitle(ConfigurationImage? image) => $"{image?.Name ?? ""} {image?.DesktopName ?? ""} — {image?.Base ?? ""}";
    public const string Cancel = "Cancel";

    public static string BitLockerKeyCopy(string storageDrive, Branding brand) =>
        $"A copy of your recovery key is stored at {(storageDrive.Length != 0 ? storageDrive : "C")}:\\wootc\\install, readable only by administrators, until Linux first starts. Linux then moves it into its own disk and seals it to this PC, so it can reach your files on every boot. Deleting your Linux data when you uninstall {brand.ProductName} erases it.";

    public static string ErrorLine(string error) => "✖ " + error;

    public static string ErrorCalm(bool pastArm) => pastArm
        ? "Your files and Windows are unharmed — everything lives in the installation folder, and the one-time startup entry has been removed again. You can safely close this and try again."
        : "Your files and Windows are unharmed — nothing outside the installation folder was changed. You can safely close this and try again.";

    public static string Calm(bool pastArm, Branding brand) => pastArm
        ? $"Your files and Windows stay untouched. {brand.ProductName} has added a one-time startup entry for the setup boot — everything else lives in one folder, Windows stays your default, and you can undo this at any time."
        : "Your files and Windows stay untouched. Everything here goes into one folder — until Linux is proven working, nothing permanent changes, and you can undo this at any time.";

    // What the progress view shows for the current event stream.
    public static IReadOnlyList<string> Notes(InstallProgress progress, string storageDrive, Branding brand)
    {
        var lines = new List<string>();
        if (progress.Error is { } error) { lines.Add(ErrorLine(error)); lines.Add(ErrorCalm(progress.PastArm)); }
        if (progress.Step == InstallProgress.BitLockerStep) lines.Add(BitLockerKeyCopy(storageDrive, brand));
        lines.Add(Calm(progress.PastArm, brand));
        return lines;
    }

    public static string DoneTitle(Branding brand) => $"{brand.Name} setup is ready";

    public static string DoneBody(ConfigurationImage? image, Branding brand) =>
        $"Preparation for {(string.IsNullOrEmpty(image?.Name) ? brand.Name : image.Name)} {image?.DesktopName ?? ""} is complete. " +
        "Click Reboot Now to begin the Linux installation. Keep your PC plugged in. " +
        "Installation time depends on your computer and any downloads it needs.";

    public const string DoneSafety =
        "Linux has not finished installing yet. If startup fails, you may need to select Windows Boot Manager from your PC's boot menu or use Windows recovery. " +
        "If BitLocker is enabled, keep its recovery key available before rebooting.";

    // Only for an image that queues MOK enrollment; the password is the
    // image's own MokManager password from the engine's catalogue.
    public static string? MokEnrollment(ConfigurationImage? image) => string.IsNullOrEmpty(image?.MokEnrollment) ? null :
        $"Driver trust for {(image.Name.Length != 0 ? image.Name : "this system")}: after setup, your PC may show a blue \"MOK management\" screen asking " +
        $"permission to trust {(image.Name.Length != 0 ? image.Name : "the")} drivers — choose Enroll MOK → Continue → Yes, and type the password " +
        $"{image.MokEnrollment}. Review the request before confirming enrollment.";

    public const string SaveWork = "Save any open work first — the restart closes other apps without asking.";
    public const string RebootLater = "Reboot Later";
    public const string RebootNow = "Reboot Now →";
}
