using System.Text.Json;

namespace Wootc.Shell.Core;

// The native window's drive loop, the counterpart of startE2EDrive in
// app/frontend/src/lib/e2e.js. Each tick reads the harness directive through
// the engine, performs at most one command through the view, and reports the
// view's state back through the engine. The engine binds every report to the
// directive it returned, so a report for another run is never written.
//
// Drive mode is diagnostic: no failure here may break the window. A failed
// read is retried on the next tick; a malformed, changed or second directive
// is never followed.

// The engine side of the loop: E2EDriveDirective, E2EDriveReport and
// E2EDriveReady over the authenticated configuration session.
public interface IE2EDriveChannel
{
    Task<string> ReadDirectiveAsync(CancellationToken cancellationToken);
    Task ReportAsync(string state, CancellationToken cancellationToken);
    Task ReadyAsync(string state, CancellationToken cancellationToken);
}

// The window side: what is on screen, and the controls a person would use.
public interface IE2EDriveView
{
    DriveObservation Observe();
    // Fill the form from the directive through the configuration view-model.
    DriveMappingObservation MapInstall(E2EDriveDirective directive);
    // The install controls a person uses. True only when the engine accepted
    // the confirmation and the install started.
    Task<bool> ClickInstallAsync();
    Task RebootAsync();
}

public sealed class E2EDriveLoop
{
    public const int PollMilliseconds = 2000;
    private readonly IE2EDriveChannel channel;
    private readonly IE2EDriveView view;
    public E2EDriveSession Session { get; } = new();

    public E2EDriveLoop(IE2EDriveChannel channel, IE2EDriveView view)
    {
        this.channel = channel ?? throw new ArgumentNullException(nameof(channel));
        this.view = view ?? throw new ArgumentNullException(nameof(view));
    }

    // The readiness marker carries only the schema and the screen, as the
    // Wails loop's does; it binds to no directive.
    public static string ReadyState(DriveScreen screen)
    {
        using var buffer = new MemoryStream();
        using (var writer = new Utf8JsonWriter(buffer))
        {
            writer.WriteStartObject();
            writer.WriteNumber("schemaVersion", 1);
            writer.WriteString("screen", screen.ToString().ToLowerInvariant());
            writer.WriteEndObject();
        }
        return System.Text.Encoding.UTF8.GetString(buffer.ToArray());
    }

    public async Task TickAsync(CancellationToken cancellationToken = default)
    {
        string raw = "";
        try { raw = await channel.ReadDirectiveAsync(cancellationToken) ?? ""; }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }
        catch { /* A transient read failure: signal readiness and retry. */ }
        if (raw.StartsWith('﻿')) raw = raw[1..];
        if (raw.Length == 0)
        {
            // No directive yet. Readiness is observable before one exists.
            try { await channel.ReadyAsync(ReadyState(view.Observe().Screen), cancellationToken); }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }
            catch { /* Best effort; the next tick retries. */ }
            return;
        }
        E2EDriveDirective directive;
        DriveCommand command;
        try
        {
            directive = E2EDriveDirective.Parse(raw);
            command = Session.Next(directive, view.Observe());
        }
        catch (Exception error) when (error is InvalidDataException or JsonException)
        {
            // A malformed directive, another run, or a second install
            // directive: never followed, never reported against.
            return;
        }
        switch (command)
        {
            case DriveCommand.MapInstall:
                try
                {
                    var outcome = view.MapInstall(directive);
                    Session.MarkMapped(directive);
                    // A refused target is reported, not swallowed. An image
                    // mismatch is reported through imageMismatch instead.
                    if (!outcome.Mapped && !outcome.ImageMismatch)
                        Session.MarkRefused(outcome.BlockedReason.Length != 0 ? outcome.BlockedReason : "The drive directive could not be mapped.");
                }
                catch (Exception error) when (error is not OperationCanceledException)
                {
                    Session.MarkMapped(directive);
                    Session.MarkRefused("The drive directive could not be mapped: " + error.Message);
                }
                break;
            case DriveCommand.ClickInstall:
                // Before the click: a click whose handler partly ran is never replayed.
                Session.MarkInstallRequested();
                bool started;
                string? failure = null;
                try { started = await view.ClickInstallAsync(); }
                catch (Exception error) when (error is not OperationCanceledException) { started = false; failure = error.Message; }
                if (started) Session.MarkInstallDriven();
                else
                {
                    // The click is never replayed, so an install that did not
                    // start ends this drive. Say why, or the harness sees a
                    // disabled form with no error and waits for nothing
                    // (native E2E run 38849303170).
                    var after = view.Observe();
                    string reason = !string.IsNullOrWhiteSpace(after.Error) ? after.Error
                        : !string.IsNullOrWhiteSpace(failure) ? "The install could not start: " + failure
                        : "The engine did not grant this plan, so the install did not start." +
                          (string.IsNullOrWhiteSpace(after.Hint) ? "" : " " + after.Hint);
                    Session.MarkRefused(reason);
                }
                break;
            case DriveCommand.Reboot:
                Session.MarkRebootDriven();
                try { await view.RebootAsync(); }
                catch (Exception error) when (error is not OperationCanceledException) { /* The report shows the done screen still up. */ }
                break;
        }
        string? report = Session.Report(directive, view.Observe());
        if (report is null) return;
        try { await channel.ReportAsync(report, cancellationToken); }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }
        catch { /* The next tick reports again. */ }
    }
}
