using System.Text.Json;
using Microsoft.UI;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Wootc.Shell.Engine;
using Wootc.Shell.Core;
using Wootc.Shell.Native;

namespace Wootc.Shell;

public sealed partial class MainWindow : Window, IE2EDriveView
{
    private readonly StartupController controller;
    private readonly IBrandedEngineConnector connector;
    private readonly Branding brand;
    private InstallGate? installGate;
    private MaintenanceGate? maintenanceGate;
    private VMGate? vmGate;
    private string configurationBrandId = "";
    private IReadOnlyList<StepDefinition> configurationSteps = Array.Empty<StepDefinition>();
    private ConsumerConfiguration? configuration;
    private bool updatingConfiguration;
    // The image and drive whose install space is being read, if any.
    private (string ImageRef, string Drive)? installSpaceRequested;
    private long configurationGeneration;
    private CancellationTokenSource? configurationRead;
    private bool closing;
    private readonly bool observeFixtureInput = Environment.GetEnvironmentVariable("WOOTC_NATIVE_PREVIEW_INPUT_OBSERVATION") == "1";
    private int passwordChanges, confirmationChanges;
    // E2E drive mode (WOOTC_E2E_DRIVE=1), the counterpart of the Wails
    // frontend's startE2EDrive. The engine answers the drive channel only when
    // its own environment enables it too.
    private readonly bool driveMode = Environment.GetEnvironmentVariable("WOOTC_E2E_DRIVE") == "1";
    private E2EDriveLoop? drive;
    private DispatcherQueueTimer? driveTimer;
    private bool driveTicking, driveConnectRequested, driveConfigurationRequested;

    public MainWindow()
    {
        InitializeComponent();
        ConfigurationButton.GotFocus += (_,_) => ConfigurationButton.StartBringIntoView(new BringIntoViewOptions { AnimationDesired=false });
        if (observeFixtureInput)
        {
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetHelpText(LinuxPassword,"InputChangeSequence:0");
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetHelpText(LinuxPasswordConfirmation,"InputChangeSequence:0");
        }
        // Local branding is available before any elevation or engine connection.
        string path = Path.Combine(AppContext.BaseDirectory, "Branding", "brand.json");
        brand = JsonSerializer.Deserialize<Branding>(File.ReadAllText(path))
            ?? throw new InvalidDataException("Preview branding is missing");
        if (string.IsNullOrWhiteSpace(brand.ProductName) || string.IsNullOrWhiteSpace(brand.Name))
            throw new InvalidDataException("Preview branding has no product or distribution identity");
        Title = $"{brand.ProductName} — Preview";
        ProductName.Text = brand.ProductName;
        DistributionName.Text = brand.Name;
        ApplyBrand(brand, BrandTheme.From(brand));
#if NATIVE_GALLERY
        // Screen gallery build: recorded engine answers, no engine process.
        connector = Wootc.Shell.Gallery.GalleryConnector.FromEnvironment(AppContext.BaseDirectory);
        Title += " — Screen gallery (recorded fixtures)";
#else
        connector = new NativeEngineConnector(AppContext.BaseDirectory, diagnostic =>
            DispatcherQueue.TryEnqueue(() => { if (!closing && diagnostic.IsCurrent()) Microsoft.UI.Xaml.Automation.AutomationProperties.SetHelpText(ConnectionStatus, diagnostic.Projection); }));
#endif
        controller = new StartupController(brand, connector);
        InstallButton.Content = $"Advanced: {InstallDisclosure.InstallVerb(brand)} with reboot";
#if !NATIVE_GALLERY
        if (driveMode) StartDrive();
#endif
        // Closing the window disconnects both sessions; the engine treats that
        // as a cancellation request for any running install.
        Closed += async (_, _) => { closing=true; driveTimer?.Stop(); InvalidateConfigurationRead(); if (installGate is not null) await installGate.DisposeAsync(); if (maintenanceGate is not null) await maintenanceGate.DisposeAsync(); if (vmGate is not null) await vmGate.DisposeAsync(); await controller.DisposeAsync(); };
    }
    // Local, validated brand assets render before any elevation request and
    // stay visible after a refusal. High contrast keeps the system palette.
    private void ApplyBrand(Branding brand, BrandTheme theme)
    {
        string palette = "system";
        if (new Windows.UI.ViewManagement.AccessibilitySettings().HighContrast) palette = "high-contrast";
        else if (theme.HasPalette)
        {
            ApplyPalette(theme);
            palette = "brand";
        }
        AutomationProperties.SetHelpText(ProductName, $"Palette: {palette}");
        string logo = Path.Combine(AppContext.BaseDirectory, "Branding", "logo.svg");
        if (File.Exists(logo))
        {
            AutomationProperties.SetName(BrandLogo, $"{brand.Name} logo");
            AutomationProperties.SetHelpText(BrandLogo, "Brand logo loading");
            BrandLogo.Visibility = Visibility.Visible;
            _ = LoadLogoAsync(logo);
        }
        else if (!string.IsNullOrWhiteSpace(brand.LogoEmoji))
        {
            BrandEmoji.Text = brand.LogoEmoji;
            AutomationProperties.SetName(BrandEmoji, brand.LogoEmoji);
            BrandEmoji.Visibility = Visibility.Visible;
        }
    }

    private async Task LoadLogoAsync(string path)
    {
        try
        {
            var source = new SvgImageSource { RasterizePixelHeight = 112 };
            using var stream = File.OpenRead(path);
            var status = await source.SetSourceAsync(stream.AsRandomAccessStream());
            if (status != SvgImageSourceLoadStatus.Success) throw new InvalidDataException($"SVG status {status}");
            BrandLogo.Source = source;
            AutomationProperties.SetHelpText(BrandLogo, "Brand logo loaded");
        }
        catch (Exception error)
        {
            // The product and distribution names remain; never fetch a fallback.
            BrandLogo.Visibility = Visibility.Collapsed;
            AutomationProperties.SetHelpText(BrandLogo, $"Brand logo failed: {error.GetType().Name}");
        }
    }

    private void ApplyPalette(BrandTheme theme)
    {
        static SolidColorBrush Brush(BrandColor color) => new(ColorHelper.FromArgb(255, color.R, color.G, color.B));
        if (theme.Background is { } background)
        {
            BrandRoot.RequestedTheme = theme.Ground == BrandGround.Dark ? ElementTheme.Dark : ElementTheme.Light;
            BrandRoot.Background = Brush(background);
            BrandCard.Background = Brush(theme.Card!.Value);
            var text = Brush(theme.Text!.Value);
            foreach (var block in new[] { ProductName, DistributionName, PreviewHeading, PreviewIntro, PreviewStatus, ConnectionStatus, StartupRouteText, StartupObservations, InstallRecoveryText })
                block.Foreground = text;
        }
        if (theme.Accent is { } accent)
        {
            // Lightweight styling: these keys feed AccentButtonStyle's states.
            var fill = Brush(accent);
            var label = Brush(theme.AccentText!.Value);
            foreach (string key in new[] { "AccentButtonBackground", "AccentButtonBackgroundPointerOver", "AccentButtonBackgroundPressed", "AccentButtonBorderBrush", "AccentButtonBorderBrushPointerOver", "AccentButtonBorderBrushPressed" })
                ConnectButton.Resources[key] = fill;
            foreach (string key in new[] { "AccentButtonForeground", "AccentButtonForegroundPointerOver", "AccentButtonForegroundPressed" })
                ConnectButton.Resources[key] = label;
        }
    }

    private async void Connect_Click(object sender, RoutedEventArgs args) => await ConnectAsync();

    private async Task ConnectAsync()
    {
        ConnectButton.IsEnabled = false;
        ConnectionStatus.Text = "Requesting administrator permission";
        await controller.RequestPermissionAsync();
        UpdateConnection();
    }

    private async void Disconnect_Click(object sender, RoutedEventArgs args)
    {
        DisconnectButton.IsEnabled = false;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetHelpText(DisconnectButton, $"ConfigurationReadPending:{configurationRead is not null}");
        InvalidateConfigurationRead();
        ConfigurationButton.IsEnabled = false;
        ConnectionStatus.Text = "Disconnecting engine";
        ClearConfiguration();
        // An open maintenance session holds no grant the user has confirmed;
        // it closes with the engine connection.
        if (maintenanceGate is { } maintenance) { maintenanceGate = null; await maintenance.DisposeAsync(); }
        // The engine stops a Linux window this session started when it closes.
        if (vmGate is { } vm) { vmGate = null; await vm.DisposeAsync(); }
        try { await controller.DisposeAsync(); }
        catch (Exception error) { ConnectionStatus.Text = $"Disconnect pending: {error.Message}"; }
        UpdateConnection();
    }

    private async void Configuration_Click(object sender, RoutedEventArgs args) => await ReadConfigurationAsync();

    private async Task ReadConfigurationAsync()
    {
        ConfigurationButton.IsEnabled = false;
        using var read = new CancellationTokenSource();
        configurationRead = read;
        long generation = ++configurationGeneration;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetHelpText(ConfigurationButton, $"ConfigurationGeneration:{generation}; State:pending");
        long flushedRequest = 0;
        try
        {
            var snapshot = await controller.ReadConfigurationAsync(read.Token, id =>
            {
                Interlocked.Exchange(ref flushedRequest, id);
                DispatcherQueue.TryEnqueue(() =>
                {
                    if (generation == configurationGeneration && ReferenceEquals(configurationRead, read))
                        Microsoft.UI.Xaml.Automation.AutomationProperties.SetHelpText(ConfigurationButton, $"ConfigurationGeneration:{generation}; Request:{id}; State:pending");
                });
            });
            if (generation != configurationGeneration || controller.Connection != ConnectionState.Ready) return;
            var observed = new ConsumerConfiguration(snapshot.BrandId);
            configurationBrandId = snapshot.BrandId;
            configurationSteps = snapshot.Steps.ToArray();
            observed.ApplyCatalogue(ConfigurationProjection.ToCatalogue(snapshot));
            updatingConfiguration = true;
            configuration = observed;
            ImageChoice.ItemsSource = observed.Images;
            StorageChoice.ItemsSource = snapshot.Storage;
            LinuxDiskSize.Value = observed.DiskSizeGb;
            LinuxEncryption.SelectedItem = LinuxEncryption.Items.OfType<Microsoft.UI.Xaml.Controls.ComboBoxItem>().Single(item => (string)item.Tag == observed.Encryption);
            LinuxWindowsLook.IsChecked = observed.WindowsLook;
            ConfigurationObservation.Text = $"Catalogue: {snapshot.CatalogueSource}; channel: {snapshot.Policy.Channel}; storage: {snapshot.StorageStatus}; installation authorization: unavailable";
            ConfigurationPanel.Visibility = Visibility.Visible;
        }
        catch { if (generation == configurationGeneration) { ClearConfiguration(); StartupObservations.Text = "Linux configuration observation is unavailable"; } }
        finally
        {
            if (ReferenceEquals(configurationRead, read)) configurationRead = null;
            if (generation == configurationGeneration) { updatingConfiguration = false; ConfigurationButton.IsEnabled = controller.Connection == ConnectionState.Ready; Microsoft.UI.Xaml.Automation.AutomationProperties.SetHelpText(ConfigurationButton, $"ConfigurationGeneration:{generation}; Request:{Interlocked.Read(ref flushedRequest)}; State:completed"); }
        }
        if (generation == configurationGeneration) RefreshConfiguration();
    }

    private void InvalidateConfigurationRead()
    {
        ++configurationGeneration;
        configurationRead?.Cancel();
    }

    private void ClearConfiguration()
    {
        configuration = null;
        ConfigurationPanel.Visibility = Visibility.Collapsed;
        ImageChoice.SelectedItem = null; StorageChoice.SelectedItem = null;
        ImageChoice.ItemsSource = null; StorageChoice.ItemsSource = null;
        LinuxUsername.Text = ""; LinuxHostname.Text = "";
        LinuxPassword.Password = ""; LinuxPasswordConfirmation.Password = ""; LinuxLuksPassphrase.Password = "";

        LinuxEncryption.SelectedItem = null; LinuxDiskSize.Value = double.NaN; LinuxWindowsLook.IsChecked = false;
        ImageFacts.Text = ""; StorageFacts.Text = ""; InstallBlockedReason.Text = "";
        _ = DiscardInstallGrantAsync();
    }

    private void ConfigurationChanged(object sender, object args)
    {
        // Optional hosted fixture change-sequence receipt only. No password value
        // is exposed and no configuration/operation capability is granted.
        if (observeFixtureInput && ReferenceEquals(sender,LinuxPassword))
        { passwordChanges=Math.Min(passwordChanges+1,1000000); Microsoft.UI.Xaml.Automation.AutomationProperties.SetHelpText(LinuxPassword,$"InputChangeSequence:{passwordChanges}"); }
        if (observeFixtureInput && ReferenceEquals(sender,LinuxPasswordConfirmation))
        { confirmationChanges=Math.Min(confirmationChanges+1,1000000); Microsoft.UI.Xaml.Automation.AutomationProperties.SetHelpText(LinuxPasswordConfirmation,$"InputChangeSequence:{confirmationChanges}"); }
        RefreshConfiguration();
    }

    private void RefreshConfiguration()
    {
        if (updatingConfiguration || configuration is null) return;
        configuration.SelectImage((ImageChoice.SelectedItem as ConfigurationImage)?.Id ?? "");
        configuration.SelectStorage((StorageChoice.SelectedItem as NativeConfigurationStorage)?.Id ?? "");
        configuration.Username = LinuxUsername.Text;
        configuration.Password = LinuxPassword.Password;

        configuration.PasswordConfirmation = LinuxPasswordConfirmation.Password;
        configuration.Hostname = LinuxHostname.Text;
        configuration.DiskSizeGb = double.IsNaN(LinuxDiskSize.Value) ? 0 : (int)LinuxDiskSize.Value;
        configuration.Encryption = (LinuxEncryption.SelectedItem as Microsoft.UI.Xaml.Controls.ComboBoxItem)?.Tag as string ?? "";
        configuration.LuksPassphrase = LinuxLuksPassphrase.Password;
        configuration.WindowsLook = LinuxWindowsLook.IsChecked == true;
        ImageFacts.Text = configuration.SelectedImage is null ? "Choose an observed image" :
            $"{configuration.SelectedImage.ImageRef}; admission: {configuration.SelectedImage.Admitted}; content verified: {configuration.SelectedImage.ContentVerified}; MOK enrollment required: {configuration.SelectedImage.RequiresMokEnrollment}";
        StorageFacts.Text = configuration.SelectedStorage is null ? "Choose an assessed volume; no drive is selected automatically" :
            $"{configuration.SelectedStorage.DriveLetter}: {configuration.SelectedStorage.FreeBytes} available bytes; partition: {configuration.SelectedStorage.PartitionGuid}; NTFS: {configuration.SelectedStorage.NtfsSerial}";
        InstallBlockedReason.Text = configuration.InstallationBlockedReason;
        _ = ReadInstallSpaceAsync();
        RenderVM();
        // Any change to the plan on screen discards an earlier grant and its
        // install session; the new plan needs its own engine check.
        _ = DiscardInstallGrantAsync();
    }

    // What the selected image needs on the selected drive beside its Linux
    // disk, from the engine (GetNativeInstallSpace). Until it answers the form
    // says so and Install stays disabled; then the disk size is lowered to
    // fit, as the Wails launchpad does. No answer falls back to the smallest
    // image's reserve; the engine still refuses a plan that does not fit.
    private async Task ReadInstallSpaceAsync()
    {
        var model = configuration;
        if (model?.PendingInstallSpace is not (string imageRef, string drive) || installSpaceRequested == (imageRef, drive)) return;
        installSpaceRequested = (imageRef, drive);
        ConfigurationInstallSpace? space = null;
        try { space = await controller.ReadInstallSpaceAsync(imageRef, drive); }
        catch { /* Unavailable: the fallback below. */ }
        if (installSpaceRequested == (imageRef, drive)) installSpaceRequested = null;
        if (!ReferenceEquals(configuration, model))
        {
            // A newer configuration read replaced this form: ask for its own.
            if (configuration is not null) RefreshConfiguration();
            return;
        }
        try
        {
            if (space is null) model.InstallSpaceUnavailable(imageRef, drive);
            else model.ApplyInstallSpace(space);
        }
        catch (InvalidDataException) { model.InstallSpaceUnavailable(imageRef, drive); }
        updatingConfiguration = true;
        try { LinuxDiskSize.Value = model.DiskSizeGb; }
        finally { updatingConfiguration = false; }
        RefreshConfiguration();
    }

    private async Task DiscardInstallGrantAsync()
    {
        if (installGate is { State: not InstallGateState.Idle }) await installGate.InvalidateAsync();
        UpdateInstallGate();
    }

    private void UpdateInstallGate()
    {
        var state = installGate?.State ?? InstallGateState.Idle;
        bool busy = state is InstallGateState.Preparing or InstallGateState.Confirming or InstallGateState.Started;
        PrepareInstallButton.IsEnabled = !busy && configuration is { FormProblem.Length: 0 } && controller.Connection == ConnectionState.Ready;
        InstallButton.IsEnabled = installGate?.CanInstall == true;
        InstallGateStatus.Text = state switch
        {
            InstallGateState.Preparing => "Checking this plan with the engine",
            InstallGateState.Granted => "The engine accepted this plan. Nothing changes until you confirm.",
            InstallGateState.Refused or InstallGateState.Failed => installGate!.Reason,
            InstallGateState.Confirming => "Starting the installation",
            InstallGateState.Started => "The installation started. Keep this window open.",
            InstallGateState.Cancelling => "Cancelling the installation",
            InstallGateState.Cancelled => "The installation was cancelled.",
            _ => "",
        };
        RenderInstallProgress(state);
    }

    // The legacy progress and done screens, word for word, from this
    // session's own install:progress events.
    private void RenderInstallProgress(InstallGateState state)
    {
        var progress = installGate?.Progress;
        bool finished = progress is not null && state is InstallGateState.Finished or InstallGateState.Restarting;
        bool installing = progress is not null && !finished && state is InstallGateState.Confirming or InstallGateState.Started or InstallGateState.Cancelling or InstallGateState.Failed;
        ProgressPanel.Visibility = installing ? Visibility.Visible : Visibility.Collapsed;
        DonePanel.Visibility = finished ? Visibility.Visible : Visibility.Collapsed;
        if (installing || finished) ConfigurationPanel.Visibility = Visibility.Collapsed;
        else if (configuration is not null) ConfigurationPanel.Visibility = Visibility.Visible;
        if (progress is null) return;
        var grant = installGate!.Grant;
        var image = configuration?.Images.FirstOrDefault(candidate => candidate.ImageRef == grant?.ImageRef);
        if (installing)
        {
            ProgressTitle.Text = InstallProgressText.Title(brand);
            ProgressSubtitle.Text = InstallProgressText.Subtitle(image);
            ProgressStep.Text = progress.StepLabel;
            ProgressMessage.Text = progress.Message;
            InstallProgressBar.Value = progress.Percent;
            ProgressNotes.Children.Clear();
            var notes = InstallProgressText.Notes(progress, grant?.StorageDrive ?? "", brand);
            for (int index = 0; index < notes.Count; index++)
            {
                var note = new TextBlock { Text = notes[index], TextWrapping = TextWrapping.Wrap };
                AutomationProperties.SetAutomationId(note, $"ProgressNote{index}");
                ProgressNotes.Children.Add(note);
            }
            ProgressSteps.Children.Clear();
            foreach (var step in progress.Steps)
            {
                var item = new TextBlock { Text = step.Label, Opacity = step.State == InstallStepState.Pending ? 0.6 : 1 };
                if (step.State == InstallStepState.Active) item.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
                AutomationProperties.SetHelpText(item, step.State.ToString());
                ProgressSteps.Children.Add(item);
            }
            CancelInstallButton.IsEnabled = state == InstallGateState.Started;
        }
        if (finished)
        {
            DoneTitle.Text = InstallProgressText.DoneTitle(brand);
            DoneBody.Text = InstallProgressText.DoneBody(image, brand);
            DoneSafety.Text = InstallProgressText.DoneSafety;
            string? mok = InstallProgressText.MokEnrollment(image);
            DoneMok.Text = mok ?? "";
            DoneMok.Visibility = mok is null ? Visibility.Collapsed : Visibility.Visible;
            DoneSaveWork.Text = InstallProgressText.SaveWork;
            RebootNowButton.IsEnabled = state == InstallGateState.Finished;
        }
    }

    private async void CancelInstall_Click(object sender, RoutedEventArgs args)
    {
        if (installGate is null) return;
        CancelInstallButton.IsEnabled = false;
        await installGate.CancelAsync();
        UpdateInstallGate();
    }

    // Reboot Later leaves the prepared restart in place, as the legacy app does.
    private void RebootLater_Click(object sender, RoutedEventArgs args) => Close();

    private async void RebootNow_Click(object sender, RoutedEventArgs args) => await RebootNowAsync();

    private async Task RebootNowAsync()
    {
        if (installGate is null) return;
        RebootNowButton.IsEnabled = false;
        try { await installGate.RebootAsync(); }
        catch (Exception error) { InstallGateStatus.Text = error.Message; }
        UpdateInstallGate();
    }

    private async void PrepareInstall_Click(object sender, RoutedEventArgs args) => await PrepareInstallAsync();

    private async Task PrepareInstallAsync()
    {
        if (configuration is null || configuration.FormProblem.Length != 0 || configurationBrandId.Length == 0) return;
        var draft = configuration.CreateDraft();
        if (installGate is null)
        {
            installGate = new InstallGate(connector, configurationBrandId);
            installGate.Changed += () => DispatcherQueue.TryEnqueue(() => { if (!closing) UpdateInstallGate(); });
        }
        var preparing = installGate.PrepareAsync(draft);
        UpdateInstallGate();
        // Whatever the check's outcome, the form shows it: a check that
        // threw must not leave the buttons as they were while it ran.
        try { await preparing; }
        finally { UpdateInstallGate(); }
    }

    // The confirmation repeats the legacy launchpad's own disclosures. Cancel
    // is the default button, so Enter never starts an install.
    private async void Install_Click(object sender, RoutedEventArgs args)
    {
        var gate = installGate;
        var grant = gate?.Grant;
        if (gate is null || !gate.CanInstall || grant is null) return;
        var disclosure = InstallDisclosure.For(brand, grant);
        var lines = new StackPanel { Spacing = 8 };
        for (int index = 0; index < disclosure.Lines.Count; index++)
        {
            var line = new TextBlock { Text = disclosure.Lines[index], TextWrapping = TextWrapping.Wrap };
            AutomationProperties.SetAutomationId(line, $"InstallDisclosure{index}");
            lines.Children.Add(line);
        }
        var dialog = new ContentDialog
        {
            Title = disclosure.Heading, Content = lines, PrimaryButtonText = disclosure.Action, CloseButtonText = disclosure.Cancel,
            DefaultButton = ContentDialogButton.Close, XamlRoot = Content.XamlRoot,
        };
        AutomationProperties.SetAutomationId(dialog, "InstallConfirmation");
        InstallButton.IsEnabled = false;
        var answer = await dialog.ShowAsync();
        if (answer == ContentDialogResult.Primary)
        {
            var confirming = gate.ConfirmAsync(configurationSteps);
            UpdateInstallGate();
            await confirming;
        }
        UpdateInstallGate();
    }

    // The legacy Linux window screens, word for word, from this session's
    // VM status and vm:progress events.
    private void RenderVM()
    {
        VMPanel.Visibility = controller.Connection == ConnectionState.Ready ? Visibility.Visible : Visibility.Collapsed;
        if (VMPanel.Visibility != Visibility.Visible) return;
        var image = ImageChoice.SelectedItem as ConfigurationImage;
        string blocked = VMText.PrepareBlockedReason(image?.ImageRef, LinuxUsername.Text, LinuxPassword.Password, LinuxPasswordConfirmation.Password);
        var view = VMScreen.For(vmGate, brand, image?.Name, blocked);
        VMLines.Children.Clear();
        foreach (var line in view.Lines)
        {
            var block = new TextBlock { Text = line.Text, TextWrapping = TextWrapping.Wrap };
            if (line.Id == "VMTitle") { block.FontSize = 20; block.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold; }
            AutomationProperties.SetAutomationId(block, line.Id);
            VMLines.Children.Add(block);
        }
        VMProgressBar.Visibility = view.ShowProgress ? Visibility.Visible : Visibility.Collapsed;
        VMProgressBar.Value = view.ProgressValue;
        VMButtons.Children.Clear();
        foreach (var action in view.Buttons)
        {
            var button = new Button { Content = action.Label, IsEnabled = action.Enabled };
            AutomationProperties.SetAutomationId(button, action.Id);
            string id = action.Id;
            button.Click += (_, _) => VM_Click(id);
            VMButtons.Children.Add(button);
        }
    }

    private async void VM_Click(string id)
    {
        if (id == "ReadVMStatus")
        {
            string? brandId = connector.AuthenticatedBrandId;
            if (brandId is null) return;
            if (vmGate is null)
            {
                vmGate = new VMGate(connector, brandId);
                var gate = vmGate;
                gate.Changed += () => DispatcherQueue.TryEnqueue(async () =>
                {
                    if (closing) return;
                    // The legacy screen read the VM again after these events.
                    if (gate.Progress?.Stage is "started" or "stopped" or "needs_recovery" or "runtime-ready" && gate.State == VMGateState.Open) await gate.RefreshAsync();
                    RenderVM();
                });
            }
            var opening = vmGate.OpenAsync();
            RenderVM();
            await opening;
            RenderVM();
            return;
        }
        var vm = vmGate;
        if (vm is null) return;
        var image = ImageChoice.SelectedItem as ConfigurationImage;
        var plan = id switch
        {
            "StartInWindow" => new NativeVMPlan { Action = VMActions.Prepare, ImageRef = image?.ImageRef, Username = LinuxUsername.Text, Password = LinuxPassword.Password },
            "SetUpRuntime" => new NativeVMPlan { Action = VMActions.InstallRuntime },
            "ShutDownLinux" => new NativeVMPlan { Action = VMActions.Stop },
            "ForceStopLinux" or "CancelSetup" => new NativeVMPlan { Action = VMActions.ForceStop },
            "StartLinuxAgain" or "BootInVM" => new NativeVMPlan { Action = VMActions.Boot },
            _ => throw new InvalidDataException("Unsupported VM action"),
        };
        if (plan.Action == VMActions.Prepare && VMText.PrepareBlockedReason(plan.ImageRef, plan.Username ?? "", plan.Password ?? "", LinuxPasswordConfirmation.Password).Length != 0) return;
        // Force stop asks the legacy question; every other action ran on the click.
        bool ask = id == "ForceStopLinux";
        var running = vm.RunAsync(plan, async _ =>
        {
            if (!ask) return true;
            var dialog = new ContentDialog
            {
                Content = new TextBlock { Text = VMText.ForceStopConfirm, TextWrapping = TextWrapping.Wrap },
                PrimaryButtonText = "OK", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close, XamlRoot = Content.XamlRoot,
            };
            AutomationProperties.SetAutomationId(dialog, "VMForceStopConfirmation");
            return await dialog.ShowAsync() == ContentDialogResult.Primary;
        });
        RenderVM();
        bool ran = await running;
        // As the legacy screen did, the password leaves the form once preparation starts.
        if (ran && plan.Action == VMActions.Prepare) { LinuxPassword.Password = ""; LinuxPasswordConfirmation.Password = ""; }
        RenderVM();
    }

    private string StepLabel(string id) => configurationSteps.FirstOrDefault(step => step.Id == id)?.Label ?? id;

    // The legacy Manage and Recovery screens, word for word. Every action
    // runs through its own install-purpose session: the engine reads the
    // installation, grants one action, and runs it on one confirmation.
    private void RenderMaintenance()
    {
        var view = controller.Connection == ConnectionState.Ready ? MaintenanceScreen.For(controller.Route, controller.Snapshot, maintenanceGate, brand, StepLabel) : null;
        MaintenancePanel.Visibility = view is null ? Visibility.Collapsed : Visibility.Visible;
        if (view is null) return;
        MaintenanceLines.Children.Clear();
        foreach (var line in view.Lines)
        {
            var block = new TextBlock { Text = line.Text, TextWrapping = TextWrapping.Wrap };
            if (line.Id is "ManageTitle" or "RecoveryTitle") { block.FontSize = 20; block.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold; }
            else if (line.Id is "ManageCardTitle" or "ManageInstalledTitle" or "RecoverySafe" or "RecoveryBootState") block.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
            AutomationProperties.SetAutomationId(block, line.Id);
            MaintenanceLines.Children.Add(block);
        }
        var info = maintenanceGate?.Info;
        DeleteLinuxData.Visibility = view.OfferDeleteData ? Visibility.Visible : Visibility.Collapsed;
        DeleteLinuxData.Content = $"{MaintenanceText.DeleteData}\n{MaintenanceText.DeleteDataDetail}";
        if (!view.OfferDeleteData) DeleteLinuxData.IsChecked = false;
        GiveSpaceBack.Visibility = view.OfferPartition && info is not null ? Visibility.Visible : Visibility.Collapsed;
        GiveSpaceBack.Content = info is null ? "" : $"{MaintenanceText.GiveBack(info)}\n{MaintenanceText.GiveBackDetail(info)}";
        if (!view.OfferPartition) GiveSpaceBack.IsChecked = false;
        MaintenanceStatus.Text = view.Status;
        MaintenanceButtons.Children.Clear();
        foreach (var action in view.Buttons)
        {
            var button = new Button { Content = action.Label, IsEnabled = action.Enabled };
            AutomationProperties.SetAutomationId(button, action.Id);
            string id = action.Id;
            button.Click += (_, _) => Maintenance_Click(id);
            MaintenanceButtons.Children.Add(button);
        }
    }

    private async void Maintenance_Click(string id)
    {
        bool recovery = controller.Route == StartupRoute.Recovery;
        switch (id)
        {
            case "CloseWindow": Close(); return;
            case "Reinstall": Configuration_Click(ConfigurationButton, new RoutedEventArgs()); return;
            case "ReadInstallation":
                string? brandId = connector.AuthenticatedBrandId;
                if (brandId is null) return;
                maintenanceGate ??= new MaintenanceGate(connector, brandId);
                var opening = maintenanceGate.OpenAsync();
                RenderMaintenance();
                await opening;
                RenderMaintenance();
                return;
        }
        var gate = maintenanceGate;
        if (gate is null || gate.State != MaintenanceGateState.Observed) return;
        var plan = new NativeMaintenancePlan
        {
            Action = id switch
            {
                "UninstallLinux" or "RemoveLinux" => MaintenanceActions.Uninstall,
                "KeepWindowsOnly" => MaintenanceActions.RestoreWindowsBoot,
                "RepairBoot" => MaintenanceActions.RepairBoot,
                "TryAgain" => MaintenanceActions.TryAgain,
                "RestartIntoLinux" => MaintenanceActions.BootLinux,
                _ => throw new InvalidDataException("Unsupported maintenance action"),
            },
            // The Recovery screen's Remove keeps the Linux data, as the legacy one did.
            DeleteRootDisk = id == "UninstallLinux" && DeleteLinuxData.IsChecked == true,
            RemovePartition = id == "UninstallLinux" && GiveSpaceBack.IsChecked == true && GiveSpaceBack.Visibility == Visibility.Visible,
        };
        var preparing = gate.PrepareAsync(plan);
        RenderMaintenance();
        await preparing;
        RenderMaintenance();
        if (!gate.CanConfirm || gate.Grant is not { } grant) return;
        string? question = MaintenanceText.Confirmation(grant, recovery, brand);
        if (question is not null)
        {
            var dialog = new ContentDialog
            {
                Content = new TextBlock { Text = question, TextWrapping = TextWrapping.Wrap },
                PrimaryButtonText = "OK", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close, XamlRoot = Content.XamlRoot,
            };
            AutomationProperties.SetAutomationId(dialog, "MaintenanceConfirmation");
            if (await dialog.ShowAsync() != ContentDialogResult.Primary)
            {
                await gate.DeclineAsync();
                RenderMaintenance();
                return;
            }
        }
        var confirming = gate.ConfirmAsync();
        RenderMaintenance();
        await confirming;
        RenderMaintenance();
    }

    private void UpdateConnection()
    {
        ConnectionStatus.Text = controller.Problem is null ? controller.Connection.ToString()
            : $"{controller.Connection}: {controller.Problem}";
        ConnectButton.IsEnabled = controller.CanRequestPermission;
        ConfigurationButton.IsEnabled = controller.Connection == ConnectionState.Ready;
        if (controller.Connection != ConnectionState.Ready) ClearConfiguration();
        ConnectButton.Content = controller.Connection == ConnectionState.PermissionDeclined ? "Retry administrator permission" : "Read startup status";
        DisconnectButton.IsEnabled = controller.Connection is ConnectionState.Ready or ConnectionState.DisconnectPending;
        DisconnectButton.Content = controller.Connection == ConnectionState.DisconnectPending ? "Retry disconnect" : "Disconnect engine";
        StartupRouteText.Text = controller.Connection == ConnectionState.Ready ? controller.Route switch
        {
            StartupRoute.Assessment => "Review your computer before installation",
            StartupRoute.Progress => "An installation is running",
            StartupRoute.Manage => "Manage the existing installation",
            StartupRoute.Recovery => "Review the previous installation attempt",
            StartupRoute.Interrupted => "Finish or remove the interrupted installation",
            _ => throw new InvalidDataException("Unsupported startup route")
        } : "Startup status has not been read";
        var observed = controller.Snapshot;
        StartupObservations.Text = observed is null ? "No authenticated startup observations" :
            $"Running: {observed.Status.Running}; Existing: {observed.Status.Existing}; Lifecycle: {observed.LastRun?.State ?? ""}; Recovery: {observed.Recovery?.Verdict ?? ""}; Install: {observed.InstallRecovery?.Class ?? ""}";
        // The engine's own text for the interrupted attempt. No action runs
        // from this preview; the safe actions need the install route.
        var interrupted = controller.Connection == ConnectionState.Ready && controller.Route == StartupRoute.Interrupted ? observed?.InstallRecovery : null;
        InstallRecoveryText.Text = interrupted is null ? "" : $"{interrupted.Title} {interrupted.Message}";
        InstallRecoveryText.Visibility = interrupted is null ? Visibility.Collapsed : Visibility.Visible;
        RenderMaintenance();
        RenderVM();
    }

    // ── E2E drive mode ───────────────────────────────────────────────────────
    // The drive performs the clicks a person makes, in the same order: read
    // the startup status (one elevation), read the Linux configuration, then
    // let E2EDriveLoop fill the form, check the plan and install.
    private void StartDrive()
    {
        drive = new E2EDriveLoop(controller, this);
        driveTimer = DispatcherQueue.CreateTimer();
        driveTimer.Interval = TimeSpan.FromMilliseconds(E2EDriveLoop.PollMilliseconds);
        driveTimer.Tick += async (_, _) => await DriveTickAsync();
        driveTimer.Start();
    }

    private async Task DriveTickAsync()
    {
        if (driveTicking || closing || drive is null) return;
        driveTicking = true;
        try
        {
            // One permission request per window: a refused elevation is not retried.
            if (!driveConnectRequested)
            {
                driveConnectRequested = true;
                await ConnectAsync();
                return;
            }
            if (controller.Connection != ConnectionState.Ready) return;
            if (configuration is null && configurationRead is null && !driveConfigurationRequested && controller.Route == StartupRoute.Assessment)
            {
                driveConfigurationRequested = true;
                await ReadConfigurationAsync();
            }
            await drive.TickAsync();
        }
        catch
        {
            // Drive mode is diagnostic and must never break the window.
        }
        finally { driveTicking = false; }
    }

    DriveObservation IE2EDriveView.Observe()
    {
        var state = installGate?.State ?? InstallGateState.Idle;
        var progress = installGate?.Progress;
        string? error = state is InstallGateState.Refused or InstallGateState.Failed ? installGate!.Reason : progress?.Error;
        DriveScreen screen;
        if (controller.Connection != ConnectionState.Ready) screen = DriveScreen.Loading;
        else if (DonePanel.Visibility == Visibility.Visible) screen = DriveScreen.Done;
        else if (ProgressPanel.Visibility == Visibility.Visible) screen = DriveScreen.Progress;
        else screen = controller.Route switch
        {
            StartupRoute.Manage => DriveScreen.Control,
            StartupRoute.Recovery or StartupRoute.Interrupted => DriveScreen.Recovery,
            StartupRoute.Progress => DriveScreen.Progress,
            _ => configuration is null ? DriveScreen.Loading : DriveScreen.Launchpad,
        };
        // The Install action is two controls here: check the plan, then Install.
        bool? disabled = screen == DriveScreen.Launchpad ? !(PrepareInstallButton.IsEnabled || InstallButton.IsEnabled) : null;
        string hint = disabled == true ? (string.IsNullOrEmpty(error) ? InstallBlockedReason.Text : error) : "";
        return new(screen, disabled, hint, progress?.Step ?? "", screen == DriveScreen.Done ? null : error,
            configuration?.SelectedImage?.ImageRef ?? "", configuration?.ObservedStorage);
    }

    DriveMappingObservation IE2EDriveView.MapInstall(E2EDriveDirective directive)
    {
        var model = configuration ?? throw new InvalidOperationException("The Linux configuration has not been read");
        var mapping = directive.ToInstallMapping();
        var outcome = model.ApplyDriveMapping(mapping, directive.RunId);
        if (!outcome.Mapped)
        {
            InstallBlockedReason.Text = outcome.BlockedReason;
            return outcome;
        }
        // Put the mapped plan on the form a person sees, then read it back
        // from those controls, as a person's edits are.
        updatingConfiguration = true;
        try
        {
            ImageChoice.SelectedItem = model.Images.Single(image => image.Id == model.SelectedImage!.Id);
            var volumes = StorageChoice.ItemsSource as IEnumerable<NativeConfigurationStorage> ?? throw new InvalidOperationException("No observed storage is on the form");
            StorageChoice.SelectedItem = volumes.Single(volume => volume.Id == model.SelectedStorage!.Id);
            LinuxUsername.Text = model.Username;
            LinuxHostname.Text = model.Hostname;
            LinuxPassword.Password = mapping.Password;
            LinuxPasswordConfirmation.Password = mapping.Password;
            LinuxLuksPassphrase.Password = mapping.LuksPassphrase;
            LinuxDiskSize.Value = model.DiskSizeGb;
            LinuxEncryption.SelectedItem = LinuxEncryption.Items.OfType<ComboBoxItem>().Single(item => (string)item.Tag == model.Encryption);
        }
        finally { updatingConfiguration = false; }
        RefreshConfiguration();
        return outcome;
    }

    // The plan check and the Install confirmation a person would accept. The
    // confirmation's words are pinned by InstallDisclosureTests; the drive
    // accepts it without drawing the dialog.
    async Task<bool> IE2EDriveView.ClickInstallAsync()
    {
        await PrepareInstallAsync();
        var gate = installGate;
        if (gate is null || !gate.CanInstall) return false;
        InstallButton.IsEnabled = false;
        var confirming = gate.ConfirmAsync(configurationSteps);
        UpdateInstallGate();
        await confirming;
        UpdateInstallGate();
        return gate.State is InstallGateState.Confirming or InstallGateState.Started or InstallGateState.Finished;
    }

    Task IE2EDriveView.RebootAsync() => RebootNowAsync();
}
