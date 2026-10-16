using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Wootc.Shell.Core;

// The E2E drive contract: the harness writes one directive file, the engine
// returns it through E2EDriveDirective, the shell operates its view-models
// and reports a state object through E2EDriveReport. The engine
// (app/e2e_drive_receipt.go) and the harness (tests/e2e/gui-drive-receipt.py)
// accept only the exact report shape built here. The shared goldens in
// tests/unit/fixtures/e2e-drive bind all three.
//
// Nothing here talks to the engine or clicks a control. The view asks for the
// next command, performs it through the same view-model a person uses, and
// tells the session what happened.
//
// An install directive names its target volume in storageId. The shell never
// falls back to "the only volume it sees": a directive without a target, or
// one whose target matches no observed volume or more than one, is refused
// and the refusal is reported as the drive error. Nothing is mapped and
// Install is never clicked.

public sealed class E2EDriveDirective
{
    public const int MaximumBytes = 16384;
    private static readonly Regex DirectiveIdPattern = new("^[0-9a-f]{32}$", RegexOptions.CultureInvariant);
    private static readonly HashSet<string> Actions = new(StringComparer.Ordinal) { "install", "reboot", "prepare-vm" };
    private static readonly HashSet<string> TextFields = new(StringComparer.Ordinal)
        { "image", "username", "password", "hostname", "encryption", "storageId" };
    private static readonly HashSet<string> Required = new(StringComparer.Ordinal)
        { "schemaVersion", "runId", "directiveId", "action" };

    public int SchemaVersion { get; private init; }
    public string RunId { get; private init; } = "";
    public string DirectiveId { get; private init; } = "";
    public string Action { get; private init; } = "";
    public string Image { get; private init; } = "";
    public string Username { get; private init; } = "";
    internal string Password { get; private init; } = "";
    public string Hostname { get; private init; } = "";
    public string Encryption { get; private init; } = "";
    public string StorageId { get; private init; } = "";
    public int DiskSizeGb { get; private init; }

    private E2EDriveDirective() { }

    // Same acceptance as the engine's e2eUniqueObject plus the frontend's
    // identity checks: an optional UTF-8 BOM, at most 16 KiB, exactly one
    // object, no duplicate or unknown keys, and a well-formed identity.
    public static E2EDriveDirective Parse(string raw)
    {
        raw ??= "";
        if (raw.StartsWith('﻿')) raw = raw[1..];
        if (raw.Length == 0) throw new InvalidDataException("No drive directive");
        if (Encoding.UTF8.GetByteCount(raw) > MaximumBytes) throw new InvalidDataException("Oversized drive directive");
        using var document = JsonDocument.Parse(raw);
        if (document.RootElement.ValueKind != JsonValueKind.Object) throw new InvalidDataException("Invalid drive directive");
        var seen = new HashSet<string>(StringComparer.Ordinal);
        string runId = "", directiveId = "", action = "";
        int schema = 0, diskSize = 0;
        var text = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var property in document.RootElement.EnumerateObject())
        {
            if (!seen.Add(property.Name)) throw new InvalidDataException("Duplicate drive directive key");
            var value = property.Value;
            switch (property.Name)
            {
                case "schemaVersion":
                    // The engine compares the raw bytes with "1"; so does this.
                    if (value.ValueKind != JsonValueKind.Number || value.GetRawText() != "1") throw new InvalidDataException("Invalid drive schema");
                    schema = 1;
                    break;
                case "runId": runId = RequireString(value); break;
                case "directiveId": directiveId = RequireString(value); break;
                case "action": action = RequireString(value); break;
                case "diskSizeGb":
                    if (value.ValueKind != JsonValueKind.Number || !value.TryGetInt32(out diskSize) || diskSize < 0)
                        throw new InvalidDataException("Invalid drive disk size");
                    break;
                default:
                    if (!TextFields.Contains(property.Name)) throw new InvalidDataException("Unknown drive directive key");
                    text[property.Name] = RequireString(value);
                    break;
            }
        }
        if (!Required.IsSubsetOf(seen) || schema != 1 || runId.Length is < 1 or > 128 ||
            !DirectiveIdPattern.IsMatch(directiveId) || !Actions.Contains(action))
            throw new InvalidDataException("Invalid drive identity");
        string Text(string name) => text.TryGetValue(name, out var found) ? found : "";
        return new E2EDriveDirective
        {
            SchemaVersion = schema, RunId = runId, DirectiveId = directiveId, Action = action,
            Image = Text("image"), Username = Text("username"), Password = Text("password"),
            Hostname = Text("hostname"), Encryption = Text("encryption"), StorageId = Text("storageId"),
            DiskSizeGb = diskSize,
        };
    }

    private static string RequireString(JsonElement value) =>
        value.ValueKind == JsonValueKind.String ? value.GetString()! : throw new InvalidDataException("Invalid drive directive text");

    public InstallDriveMapping ToInstallMapping() => Action != "install"
        ? throw new InvalidOperationException("Only an install directive maps to the Linux configuration")
        : new InstallDriveMapping
        {
            SchemaVersion = SchemaVersion, RunId = RunId, DirectiveId = DirectiveId, Action = Action,
            ImageRef = Image, Username = Username, Password = Password, Hostname = Hostname,
            DiskSizeGb = DiskSizeGb, Encryption = Encryption, StorageId = StorageId,
        };

    public override string ToString() => $"E2E drive directive {Action} {DirectiveId} (private configuration omitted)";
}

// A drive directive the shell will not act on. The message is what the
// report's error field carries.
public sealed class E2EDriveRefusal : Exception
{
    public E2EDriveRefusal(string message) : base(message) { }
}

// Resolves an install directive's storageId against the engine's storage
// observation. storageId names a volume either by the engine's storage id
// (exact) or by its drive letter ("C", "c:", "C:" all name C:). The harness
// cannot know engine-derived ids in advance, so the drive letter is allowed;
// the match is still explicit and never inferred from what is on screen.
public static class E2EDriveTarget
{
    public const string MissingTarget =
        "The install drive directive names no target volume (storageId). The shell never picks one; name a volume ID or drive letter.";

    public static ConfigurationStorage Resolve(string? storageId, IReadOnlyList<ConfigurationStorage> observed)
    {
        ArgumentNullException.ThrowIfNull(observed);
        if (string.IsNullOrWhiteSpace(storageId)) throw new E2EDriveRefusal(MissingTarget);
        string? letter = DriveLetterForm(storageId);
        var matches = observed.Where(volume => volume is not null &&
            (string.Equals(volume.Id, storageId, StringComparison.Ordinal) ||
             (letter is not null && DriveLetterForm(volume.DriveLetter) == letter))).Distinct().ToArray();
        // A huge storageId must not push the report past the engine's size cap.
        // Messages avoid apostrophes and quotes, which the report writer escapes.
        string named = storageId.Length <= 64 ? storageId : $"({storageId.Length} characters)";
        return matches.Length switch
        {
            1 => matches[0],
            0 => throw new E2EDriveRefusal($"The install drive directive names target volume {named}, which matches no observed storage."),
            _ => throw new E2EDriveRefusal($"The install drive directive names target volume {named}, which matches more than one observed storage entry."),
        };
    }

    // "C", "c", "C:" and "c:" all normalise to "C:"; anything else is not a drive letter.
    public static string? DriveLetterForm(string? value) =>
        value is { Length: 1 or 2 } && char.IsAsciiLetter(value[0]) && (value.Length == 1 || value[1] == ':')
            ? char.ToUpperInvariant(value[0]) + ":" : null;
}

// Screen names the harness accepts (tests/e2e/gui-drive-receipt.py SCREENS).
public enum DriveScreen { Loading, Launchpad, Progress, Done, Control, Recovery }

// What the view observed on this poll. InstallButtonDisabled is null when
// the Install control is not on screen. Storage is the engine's storage
// observation (ConsumerConfiguration.ObservedStorage), null until the
// authenticated configuration has been read.
public sealed record DriveObservation(DriveScreen Screen, bool? InstallButtonDisabled, string Hint,
    string ProgressStep, string? Error, string SelectedRef, IReadOnlyList<ConfigurationStorage>? Storage = null);

// Refuse: do nothing to the form; the session's DriveError says why and the
// report carries it.
public enum DriveCommand { None, MapInstall, ClickInstall, Reboot, Refuse }

public sealed class E2EDriveSession
{
    private string? runId;
    private string? installDirectiveId;
    private string? mappedDirectiveId;
    private string wantImage = "";
    public bool InstallRequested { get; private set; }
    public bool InstallDriven { get; private set; }
    public bool RebootDriven { get; private set; }
    // Why this session refused the install directive. Once set, the session
    // never maps or clicks for this run, and every report carries it.
    public string? DriveError { get; private set; }

    // One command per poll. The view performs it, then reports the outcome
    // with the matching Mark method. A changed run or a second install
    // directive is refused; the session never follows a different run.
    public DriveCommand Next(E2EDriveDirective directive, DriveObservation observed)
    {
        ArgumentNullException.ThrowIfNull(directive);
        ArgumentNullException.ThrowIfNull(observed);
        if (runId is not null && runId != directive.RunId) throw new InvalidDataException("Changed drive run");
        runId = directive.RunId;
        switch (directive.Action)
        {
            case "install":
                if (installDirectiveId is not null && installDirectiveId != directive.DirectiveId)
                    throw new InvalidDataException("Changed install directive");
                installDirectiveId = directive.DirectiveId;
                wantImage = directive.Image;
                if (DriveError is not null) return DriveCommand.Refuse;
                // A directive without a target is refused on sight, whatever
                // the screen or the number of volumes.
                if (string.IsNullOrWhiteSpace(directive.StorageId)) return Refuse(E2EDriveTarget.MissingTarget);
                if (InstallRequested || observed.Screen != DriveScreen.Launchpad) return DriveCommand.None;
                if (mappedDirectiveId != directive.DirectiveId)
                {
                    // Storage not read yet: wait, never guess.
                    if (observed.Storage is null) return DriveCommand.None;
                    try { E2EDriveTarget.Resolve(directive.StorageId, observed.Storage); }
                    catch (E2EDriveRefusal refusal) { return Refuse(refusal.Message); }
                    return DriveCommand.MapInstall;
                }
                // Integrity gate: install only the image the directive named.
                if (directive.Image.Length != 0 && observed.SelectedRef != directive.Image) return DriveCommand.None;
                return observed.InstallButtonDisabled == false ? DriveCommand.ClickInstall : DriveCommand.None;
            case "reboot":
                return observed.Screen == DriveScreen.Done && InstallDriven && !RebootDriven &&
                    installDirectiveId == directive.DirectiveId ? DriveCommand.Reboot : DriveCommand.None;
            default:
                // The native shell has no VM preparation surface yet.
                return DriveCommand.None;
        }
    }

    private DriveCommand Refuse(string reason)
    {
        DriveError ??= reason;
        return DriveCommand.Refuse;
    }

    public void MarkMapped(E2EDriveDirective directive) => mappedDirectiveId = directive.DirectiveId;

    // The view calls this when ConsumerConfiguration.ApplyDriveMapping refused
    // the target volume, so that refusal is reported, not swallowed.
    public void MarkRefused(string reason)
    {
        if (string.IsNullOrWhiteSpace(reason)) throw new ArgumentException("A drive refusal needs a reason");
        DriveError ??= reason;
    }

    // Call before the click: a click whose handler partly ran is never replayed.
    public void MarkInstallRequested() => InstallRequested = true;
    public void MarkInstallDriven() => InstallDriven = true;
    public void MarkRebootDriven() => RebootDriven = true;

    // The exact twelve-field report the engine binds to the directive. VM
    // preparation reports are refused by the engine, so none is built.
    public string? Report(E2EDriveDirective directive, DriveObservation observed)
    {
        if (directive.Action is not ("install" or "reboot")) return null;
        // A refused target is the reason nothing was selected; it is reported
        // as the error, not as an image the catalogue lacks.
        bool mismatch = DriveError is null && wantImage.Length != 0 && observed.Screen == DriveScreen.Launchpad &&
            !InstallDriven && observed.SelectedRef != wantImage;
        string? error = DriveError ?? (string.IsNullOrEmpty(observed.Error) ? null : observed.Error);
        using var buffer = new MemoryStream();
        using (var writer = new Utf8JsonWriter(buffer))
        {
            writer.WriteStartObject();
            writer.WriteNumber("schemaVersion", 1);
            writer.WriteString("runId", directive.RunId);
            writer.WriteString("directiveId", directive.DirectiveId);
            writer.WriteString("action", directive.Action);
            writer.WriteString("screen", observed.Screen.ToString().ToLowerInvariant());
            writer.WriteBoolean("installDriven", InstallDriven);
            if (observed.InstallButtonDisabled is bool disabled) writer.WriteBoolean("installBtnDisabled", disabled);
            else writer.WriteNull("installBtnDisabled");
            writer.WriteString("hint", observed.Hint ?? "");
            writer.WriteString("progressStep", observed.ProgressStep ?? "");
            if (error is null) writer.WriteNull("error");
            else writer.WriteString("error", error);
            writer.WriteString("selectedRef", observed.SelectedRef ?? "");
            writer.WriteBoolean("imageMismatch", mismatch);
            writer.WriteEndObject();
        }
        return Encoding.UTF8.GetString(buffer.ToArray());
    }
}
