using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;

// Hydra - standalone launcher + skills manager + reference for the Claude CLI.
class Hydra : Form
{
    const int ProxyPort = 8787;
    const int OllamaPort = 11434;
    const string TermReady = "Ready";
    const string TermWorking = "Working";
    const string TermWaiting = "Waiting for User";
    const string TermStopped = "Stopped / Token Limit";
    static readonly string HomeDir     = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    static readonly string StateDir    = Path.Combine(HomeDir, ".claude-manager");
    static readonly string ManagedBin  = Path.Combine(StateDir, "bin");   // native toolchain the app provisions (on PATH)
    static readonly string RecentFile  = Path.Combine(StateDir, "recent.txt");
    static readonly string SettingsFile= Path.Combine(StateDir, "settings.txt");
    static readonly string SkillsDir   = Path.Combine(HomeDir, ".claude", "skills");
    static readonly string DisabledDir = Path.Combine(HomeDir, ".claude", "skills-disabled");
    static readonly string CodexSkillsDir = Path.Combine(HomeDir, ".agents", "skills");
    static readonly string CodexDisabledDir = Path.Combine(HomeDir, ".agents", "skills-disabled");
    static readonly string PluginsFile = Path.Combine(HomeDir, ".claude", "plugins", "installed_plugins.json");
    static readonly string ClaudeSettings = Path.Combine(HomeDir, ".claude", "settings.json");
    static readonly string CodexDir    = Environment.GetEnvironmentVariable("CODEX_HOME") ?? Path.Combine(HomeDir, ".codex");
    static readonly string CodexAgents = Path.Combine(CodexDir, "AGENTS.md");
    static readonly string CodexRtk    = Path.Combine(CodexDir, "RTK.md");
    static readonly string EventsDir   = Path.Combine(StateDir, "events");
    static readonly string SessDir     = Path.Combine(StateDir, "sessions");
    static readonly object[] ClaudeModelChoices = { "Default", "claude-fable-5", "claude-opus-4-8", "claude-sonnet-5", "claude-haiku-4-5" };
    static readonly object[] ChatGptModelChoices = { "Default", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5", "gpt-5.4", "gpt-5.4-mini", "gpt-5.3-codex-spark" };
    static bool screenshotMode;

    // palette — dark liquid-glass
    static readonly Color Bg        = Color.FromArgb(22, 22, 25);
    static readonly Color Field     = Color.FromArgb(43, 43, 51);
    static readonly Color FieldHi   = Color.FromArgb(58, 58, 68);
    static readonly Color Panel2    = Color.FromArgb(40, 40, 45);
    static readonly Color Accent    = Color.FromArgb(217, 119, 87);
    static readonly Color AccentHi  = Color.FromArgb(232, 140, 110);
    static readonly Color TextDim   = Color.FromArgb(165, 165, 175);
    static readonly Color TextFaint = Color.FromArgb(130, 130, 140);
    static readonly Color Green     = Color.FromArgb(120, 200, 120);
    static readonly Color Yellow    = Color.FromArgb(210, 185, 110);

    // nav state
    readonly List<Button> navButtons = new List<Button>();
    readonly List<Control> contentPanels = new List<Control>();

    TextBox pathBox, extraBox, glossarySearch;
    ComboBox agentCombo, modelCombo, permCombo;
    CheckBox hrCheck, rtCheck, cvCheck, continueChk;
    Label hrStatus, rtStatus, cvStatus, skillsCount, compAdvisory;
    bool suppressCaveman, suppressRtk, loadingSettings, refreshingModelChoices;
    string claudeLaunchModel = "Default", codexLaunchModel = "Default", activeModelAgent = "Claude";
    Button launchBtn;   // the "+ New" terminal button; shows the active model + compression mix
    ToolTip tabTip;
    ComboBox termAgentCombo;
    Button recentButton;
    ContextMenuStrip recentMenu;
    ListView skillsList, glossaryList;
    List<GEntry> glossary;

    // live UI animation (breathing launch button, pulsing header dot, spinning term tabs)
    Panel headerDot;
    System.Windows.Forms.Timer animTimer;
    double animT;

    // custom (frameless) window chrome
    Panel titleBar;
    Button btnMin, btnMax, btnClose;
    PictureBox botLogo;
    static readonly Color TitleBg = Color.FromArgb(16, 16, 18);
    Panel sidebar, sidebarOllamaDot;
    Label sidebarProxyStatus, sidebarCounts;

    // terminals + alerts
    FlowLayoutPanel termTabs;
    TableLayoutPanel terminalRoot;
    Panel termHost;
    Panel termEmptyState;
    TextBox termPathBox;
    TermSession selectedTerm;
    NotifyIcon tray;
    System.Windows.Forms.Timer termTimer;
    FileSystemWatcher evWatcher;
    readonly List<TermSession> sessions = new List<TermSession>();

    // Optional local inference. Never started during app launch; Hydra only owns
    // the exact `ollama serve` process created by the Start Ollama button.
    Process ollamaProcess;
    Button ollamaButton, ollamaTerminalButton;
    Label ollamaStatus;
    System.Windows.Forms.Timer ollamaTimer;
    bool ollamaProbePending, ollamaStartPending;

    // saas builder — unified one-page lifecycle (Vision / Deploy / Subscriptions)
    TextBox saasName, saasFolder, saasPitch, saasFeatures, saasStatus;
    ComboBox saasAuth, saasPay, saasBuildAgent, saasBuildModel, saasPreset, saasAI;
    ComboBox saasTarget, saasBackend, saasRegion, saasRepoVis, saasSubProvider, saasEmailProvider;
    TextBox saasGcpProject, saasServiceName, saasPublicDir, saasTiers, saasTrial, saasFromEmail;
    Label saasProgress;   // live launch checklist
    Label saasStackPreview;   // live "your stack" preview — what ⚡ instant build will use

    // setup / bootstrap (install the CLI + tools + skills from scratch)
    TextBox setupOut;
    Label setupStatus;
    Button setupAllBtn, setupUpdBtn;
    Label setupAllCap;
    bool setupBusy;

    [STAThread]
    static void Main(string[] args)
    {
        // Hook-callback mode: Claude Code invokes this exe from a per-session
        // Notification/Stop/UserPromptSubmit hook. Drop an event file and exit
        // (winexe => no window flashes). The running manager watches EventsDir.
        if (args.Length >= 1 && args[0] == "--hook")
        {
            HandleHook(args);
            return;
        }
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        try
        {
            int screenshot = Array.IndexOf(args, "--screenshot");
            screenshotMode = screenshot >= 0 && screenshot + 1 < args.Length;
            int screenshotTab = 0;
            int tabArg = Array.IndexOf(args, "--tab");
            if (tabArg >= 0 && tabArg + 1 < args.Length) int.TryParse(args[tabArg + 1], out screenshotTab);
            var mgr = new Hydra();
            if (Array.IndexOf(args, "--demo") >= 0) mgr.EnableDemo();
            if (Array.IndexOf(args, "--demolaunch") >= 0) mgr.EnableDemoLaunch();
            if (screenshotMode) mgr.EnableScreenshot(args[screenshot + 1], screenshotTab);
            Application.Run(mgr);
        }
        catch (Exception ex)
        {
            MessageBox.Show("Hydra could not start:\n\n" + ex.Message,
                "Hydra", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }

    // Self-test for the big "Launch Claude" button: sit on the Launch tab, press it,
    // and prove the resulting session embeds as a tab INSIDE the manager (not external).
    public void EnableDemoLaunch() { Shown += (s, e) => RunLaunchDemo(); }

    // Native Windows render contract used by CI. It captures the actual WinForms
    // control tree after first layout, then exits without requiring user input.
    public void EnableScreenshot(string path, int tab)
    {
        Shown += (s, e) => {
            SelectNav(Math.Max(0, Math.Min(4, tab)));
            var timer = new System.Windows.Forms.Timer { Interval = 750 };
            timer.Tick += (a, b) => {
                timer.Stop();
                try
                {
                    Refresh();
                    Application.DoEvents();
                    string directory = Path.GetDirectoryName(Path.GetFullPath(path));
                    if (!string.IsNullOrEmpty(directory)) Directory.CreateDirectory(directory);
                    using (var bitmap = new Bitmap(Width, Height, PixelFormat.Format32bppArgb))
                    {
                        using (var graphics = Graphics.FromImage(bitmap))
                        {
                            IntPtr hdc = graphics.GetHdc();
                            try
                            {
                                if (!PrintWindow(Handle, hdc, 2))
                                    throw new InvalidOperationException("PrintWindow could not capture the composed Hydra window.");
                            }
                            finally { graphics.ReleaseHdc(hdc); }
                        }
                        bitmap.Save(path, ImageFormat.Png);
                    }
                }
                catch (Exception ex)
                {
                    Environment.ExitCode = 1;
                    try { File.WriteAllText(path + ".error.txt", ex.ToString()); } catch { }
                }
                Environment.Exit(Environment.ExitCode);
            };
            timer.Start();
        };
    }

    void RunLaunchDemo()
    {
        SelectNav(0);                                   // start on the Launch tab
        if (pathBox != null) pathBox.Text = HomeDir;    // a valid folder
        var t = new System.Windows.Forms.Timer { Interval = 700 };
        t.Tick += (s, e) => { t.Stop(); if (launchBtn != null) launchBtn.PerformClick(); };
        t.Start();                                      // click the real button after the UI settles
    }

    // Self-test: auto-open two embedded terminals on the Terminals tab, then switch
    // between them — used to prove the in-app tabbed embedding end-to-end.
    public void EnableDemo() { Shown += (s, e) => RunEmbedDemo(); }

    void RunEmbedDemo()
    {
        SelectNav(0);                       // Workspace tab (terminals live here now)
        SpawnDemoTerminal("Demo A", true, true, false);    // Headroom + RTK
        SpawnDemoTerminal("Demo B", false, true, true);    // RTK + Caveman (B selected)
        var t = new System.Windows.Forms.Timer { Interval = 3500 };
        t.Tick += (s, e) => { t.Stop(); if (sessions.Count > 0) SelectTerm(sessions[0]); }; // switch to A
        t.Start();
    }

    void SpawnDemoTerminal(string label, bool hr, bool rt, bool cv)
    {
        string folder = HomeDir;
        string id = Guid.NewGuid().ToString("N").Substring(0, 12);
        var sess = new TermSession { Id = id, Folder = folder, Agent = "Claude", Model = "demo", Task = label,
            Name = "T" + (sessions.Count + 1) + "  " + label, CHeadroom = hr, CRtk = rt, CCaveman = cv };
        string inner = "title Claude " + id + " & cls & echo ================================================"
            + " & echo   EMBEDDED CLAUDE SESSION: " + label
            + " & echo   This console is running INSIDE Hydra (not external)."
            + " & echo ================================================ & echo.";
        try
        {
            var psi = new ProcessStartInfo("conhost.exe", "cmd.exe /k " + inner)
            { UseShellExecute = false, CreateNoWindow = false, WorkingDirectory = folder };
            sess.Proc = Process.Start(psi);
        }
        catch { return; }
        sess.Status = TermWorking; sess.Color = Accent;
        sessions.Add(sess);
        selectedTerm = sess;
        RefreshTermList();
        ShowSelectedTerminal();
    }

    static void HandleHook(string[] args)
    {
        try
        {
            string ev = args.Length >= 2 ? args[1] : "stop";
            string id = "";
            for (int i = 0; i < args.Length - 1; i++)
                if (args[i] == "--session") { id = args[i + 1]; break; }
            if (id.Length == 0) return;
            string payload = "";
            try
            {
                using (var input = new StreamReader(Console.OpenStandardInput(), Encoding.UTF8))
                    payload = input.ReadToEnd();
            }
            catch { }
            Directory.CreateDirectory(EventsDir);
            string file = Path.Combine(EventsDir, id + "__" + ev + "__" + DateTime.Now.Ticks + ".evt");
            string temp = file + ".tmp";
            File.WriteAllText(temp, payload);
            File.Move(temp, file);
        }
        catch { }
    }

    public Hydra()
    {
        Directory.CreateDirectory(StateDir);
        Directory.CreateDirectory(EventsDir);
        Directory.CreateDirectory(SessDir);
        Directory.CreateDirectory(ManagedBin);
        // The app's OWN managed bin comes FIRST on PATH so natively-bundled tools (rtk, etc.)
        // always resolve — even on a PC where the user has installed nothing. Launched
        // terminals inherit this process PATH. This is what makes Hydra self-dependent.
        try {
            string cur = Environment.GetEnvironmentVariable("PATH") ?? "";
            if (cur.IndexOf(ManagedBin, StringComparison.OrdinalIgnoreCase) < 0)
                Environment.SetEnvironmentVariable("PATH", ManagedBin + ";" + cur, EnvironmentVariableTarget.Process);
        } catch { }
        bool firstRun = !File.Exists(SettingsFile);
        glossary = BuildGlossary();
        BuildUi();
        LoadSettings();
        RefreshRecent();
        UpdateProxyStatus();
        UpdateRtkStatus();
        UpdateCavemanStatus();
        UpdateLaunchText();
        UpdateCompressionAdvisory();
        LoadSkills();
        RenderGlossary("");
        InitAlerts();
        InitOllama();
        if (!screenshotMode)
        {
            EnsureDefaultCompression(firstRun);
            ProvisionNativeToolchain();   // make claude/rtk/caveman native — no manual download
        }
        FormClosing += (s, e) => Shutdown();
    }

    void InitAlerts()
    {
        try { foreach (var f in Directory.GetFiles(EventsDir, "*.evt")) File.Delete(f); } catch { }

        tray = new NotifyIcon { Icon = AppIcon() ?? SystemIcons.Application, Visible = true, Text = "Hydra" };
        tray.BalloonTipClicked += (s, e) => { Show(); WindowState = FormWindowState.Normal; Activate(); };

        evWatcher = new FileSystemWatcher(EventsDir, "*.evt") { EnableRaisingEvents = true };
        evWatcher.Created += (s, e) => { try { BeginInvoke((Action<string>)OnEventFile, e.FullPath); } catch { } };
        evWatcher.Renamed += (s, e) => { try { BeginInvoke((Action<string>)OnEventFile, e.FullPath); } catch { } };

        termTimer = new System.Windows.Forms.Timer { Interval = 400 };
        termTimer.Tick += (s, e) => TermTick();
        termTimer.Start();

        // Re-hand keyboard focus to the embedded console whenever the manager is activated.
        Activated += (s, e) => { var sel = SelectedSession(); if (sel != null && sel.Embedded) FocusConsole(sel.Hwnd); };

        // Live "alive" motion: breathe the Launch button, pulse the header dot, spin working tabs.
        animTimer = new System.Windows.Forms.Timer { Interval = 55 };
        animTimer.Tick += (s, e) => AnimTick();
        animTimer.Start();
    }

    void InitOllama()
    {
        // Status polling observes an already-running server, but construction is
        // deliberately side-effect free: Ollama remains off until the user acts.
        QueueOllamaRefresh();
        ollamaTimer = new System.Windows.Forms.Timer { Interval = 2500 };
        ollamaTimer.Tick += (s, e) => QueueOllamaRefresh();
        ollamaTimer.Start();
    }

    void QueueOllamaRefresh()
    {
        if (ollamaProbePending || IsDisposed || Disposing) return;
        ollamaProbePending = true;
        ThreadPool.QueueUserWorkItem(_ => {
            bool reachable = TestPort(OllamaPort);
            bool installed = FindOllamaExecutable() != null;
            try
            {
                BeginInvoke((Action)(() => {
                    ollamaProbePending = false;
                    ApplyOllamaState(reachable, installed);
                }));
            }
            catch { ollamaProbePending = false; }
        });
    }

    void ApplyOllamaState(bool reachable, bool installed)
    {
        if (ollamaButton == null || ollamaStatus == null) return;
        bool owned = false;
        try { owned = ollamaProcess != null && !ollamaProcess.HasExited; }
        catch { ollamaProcess = null; }

        if (owned)
        {
            ollamaButton.Text = "■   Stop Ollama";
            ollamaButton.Enabled = true;
            ollamaStatus.Text = reachable ? "Ollama · local server running" : "Ollama · starting on 127.0.0.1:" + OllamaPort;
            ollamaStatus.ForeColor = reachable ? Green : Yellow;
            if (sidebarOllamaDot != null) sidebarOllamaDot.BackColor = reachable ? Green : Yellow;
        }
        else if (reachable)
        {
            ollamaProcess = null;
            ollamaButton.Text = "●   Ollama Running";
            ollamaButton.Enabled = false;
            ollamaStatus.Text = "Ollama · managed outside Hydra";
            ollamaStatus.ForeColor = Green;
            if (sidebarOllamaDot != null) sidebarOllamaDot.BackColor = Green;
        }
        else
        {
            ollamaProcess = null;
            ollamaButton.Text = "▶   Start Ollama";
            ollamaButton.Enabled = true;
            ollamaStatus.Text = installed ? "Ollama · off" : "Ollama · not installed";
            ollamaStatus.ForeColor = installed ? TextFaint : Yellow;
            if (sidebarOllamaDot != null) sidebarOllamaDot.BackColor = installed ? TextFaint : Yellow;
        }
    }

    void ToggleOllama()
    {
        bool owned = false;
        try { owned = ollamaProcess != null && !ollamaProcess.HasExited; } catch { }
        if (owned) { StopOwnedOllama(); QueueOllamaRefresh(); return; }
        if (ollamaStartPending) return;
        ollamaStartPending = true;
        ollamaButton.Enabled = false;
        ollamaButton.Text = "…   Checking Ollama";
        ThreadPool.QueueUserWorkItem(_ => {
            bool reachable = TestPort(OllamaPort);
            string executable = FindOllamaExecutable();
            try
            {
                BeginInvoke((Action)(() => {
                    ollamaStartPending = false;
                    if (reachable) { ApplyOllamaState(true, executable != null); return; }
                    if (executable == null)
                    {
                        MessageBox.Show("Install Ollama from ollama.com, then try again. Hydra never installs it silently.",
                            "Ollama", MessageBoxButtons.OK, MessageBoxIcon.Information);
                        ApplyOllamaState(false, false);
                        return;
                    }
                    StartOwnedOllama(executable);
                }));
            }
            catch { ollamaStartPending = false; }
        });
    }

    void StartOwnedOllama(string executable)
    {
        try
        {
            var psi = new ProcessStartInfo(executable, "serve")
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                WorkingDirectory = HomeDir
            };
            psi.EnvironmentVariables["OLLAMA_HOST"] = "127.0.0.1:" + OllamaPort;
            Process started = Process.Start(psi);
            if (started == null) throw new InvalidOperationException("Ollama did not create a process.");
            ollamaProcess = started;
            started.EnableRaisingEvents = true;
            started.Exited += (s, e) => {
                try { BeginInvoke((Action)(() => {
                    if (object.ReferenceEquals(ollamaProcess, started)) ollamaProcess = null;
                    QueueOllamaRefresh();
                })); } catch { }
            };
            ApplyOllamaState(false, true);
            QueueOllamaRefresh();
        }
        catch (Exception ex)
        {
            ollamaProcess = null;
            MessageBox.Show("Could not start Ollama:\n" + ex.Message, "Ollama", MessageBoxButtons.OK, MessageBoxIcon.Error);
            QueueOllamaRefresh();
        }
    }

    void StopOwnedOllama()
    {
        Process process = ollamaProcess;
        ollamaProcess = null;
        try
        {
            if (process != null && !process.HasExited)
            {
                var kill = new ProcessStartInfo("taskkill", "/PID " + process.Id + " /T /F")
                    { UseShellExecute = false, CreateNoWindow = true };
                Process.Start(kill);
            }
        }
        catch { }
    }

    void OpenOllamaTerminal()
    {
        string executable = FindOllamaExecutable();
        if (executable == null)
        {
            MessageBox.Show("Install Ollama from ollama.com, then try again. Hydra never installs it silently.",
                "Ollama", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }

        bool running = TestPort(OllamaPort);
        string id = Guid.NewGuid().ToString("N").Substring(0, 12);
        string task = running ? "Manage local models" : "Serve local models";
        string command = running
            ? CmdQ(executable) + " ps"
            : "set \"OLLAMA_HOST=127.0.0.1:" + OllamaPort + "\" && " + CmdQ(executable) + " serve";
        var sess = new TermSession {
            Id = id, Folder = HomeDir, Agent = "Ollama", Model = "Local server",
            Task = task, Name = TabHint(task, HomeDir), Status = running ? TermReady : TermWorking,
            Color = running ? Green : Accent
        };
        try
        {
            var psi = new ProcessStartInfo("conhost.exe", "cmd.exe /k title Ollama " + id + " & " + command)
                { UseShellExecute = false, CreateNoWindow = false, WorkingDirectory = HomeDir };
            sess.Proc = Process.Start(psi);
        }
        catch (Exception ex)
        {
            MessageBox.Show("Could not open Ollama terminal:\n" + ex.Message, "Ollama", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }
        sessions.Add(sess);
        selectedTerm = sess;
        SelectNav(0);
        RefreshTermList();
        ShowSelectedTerminal();
    }

    // Keyboard shortcuts: Ctrl+1..5 switch tabs, Ctrl+T new terminal, Ctrl+W close terminal.
    protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
    {
        if ((keyData & (Keys.Control | Keys.Alt)) == Keys.Control)
        {
            Keys k = keyData & Keys.KeyCode;
            if (k >= Keys.D1 && k <= Keys.D5) { SelectNav((int)(k - Keys.D1)); return true; }
            if (k == Keys.T) { SelectNav(0); NewTerminal(termPathBox != null ? termPathBox.Text : null); return true; }
            if (k == Keys.W) { CloseSelectedTerminal(); return true; }
        }
        return base.ProcessCmdKey(ref msg, keyData);
    }

    void AnimTick()
    {
        animT += 0.055;
        float pulse = (float)(0.5 + 0.5 * Math.Sin(animT));           // 0..1 breathing
        if (headerDot != null)
            headerDot.BackColor = Lerp(Accent, AccentHi, pulse);
        // keep the working-session spinners rotating
        if (termTabs != null)
        {
            bool anyLive = false;
            foreach (var t in sessions)
            if (t.Status == TermWorking) { anyLive = true; break; }
            if (anyLive)
                foreach (Control c in termTabs.Controls) c.Invalidate();
        }
    }

    void Shutdown()
    {
        try { if (termTimer != null) termTimer.Stop(); } catch { }
        try { if (animTimer != null) animTimer.Stop(); } catch { }
        try { if (ollamaTimer != null) ollamaTimer.Stop(); } catch { }
        try { if (evWatcher != null) evWatcher.EnableRaisingEvents = false; } catch { }
        StopOwnedOllama();
        foreach (var s in sessions.ToArray()) KillSession(s);
        try { if (tray != null) { tray.Visible = false; tray.Dispose(); } } catch { }
    }

    // ---------- small helpers ----------
    static bool TestPort(int p)
    {
        try { using (var c = new TcpClient()) { var r = c.BeginConnect("127.0.0.1", p, null, null);
            if (r.AsyncWaitHandle.WaitOne(300)) { c.EndConnect(r); return true; } return false; } }
        catch { return false; }
    }
    static bool OnPath(string exe)
    {
        string p = Environment.GetEnvironmentVariable("PATH") ?? "";
        foreach (var dir in p.Split(';')) { try { if (dir.Length > 0 && File.Exists(Path.Combine(dir, exe))) return true; } catch { } }
        return false;
    }
    static string FindOllamaExecutable()
    {
        string path = Environment.GetEnvironmentVariable("PATH") ?? "";
        foreach (var dir in path.Split(';'))
        {
            try
            {
                string candidate = Path.Combine(dir.Trim().Trim('"'), "ollama.exe");
                if (File.Exists(candidate)) return candidate;
            }
            catch { }
        }
        string[] candidates = {
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "Ollama", "ollama.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Ollama", "ollama.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), "Ollama", "ollama.exe")
        };
        foreach (var candidate in candidates) if (File.Exists(candidate)) return candidate;
        return null;
    }
    static void CopyDir(string src, string dst)
    {
        Directory.CreateDirectory(dst);
        foreach (var f in Directory.GetFiles(src)) File.Copy(f, Path.Combine(dst, Path.GetFileName(f)), true);
        foreach (var d in Directory.GetDirectories(src)) CopyDir(d, Path.Combine(dst, Path.GetFileName(d)));
    }
    static void ReadMeta(string skillMd, out string name, out string desc)
    {
        name = ""; desc = "";
        try
        {
            int dashes = 0; bool inFm = false;
            foreach (var line in File.ReadAllLines(skillMd))
            {
                if (line.Trim() == "---") { dashes++; if (dashes == 1) { inFm = true; continue; } if (dashes >= 2) break; }
                if (inFm)
                {
                    if (name == "" && line.StartsWith("name:")) name = line.Substring(5).Trim();
                    else if (desc == "" && line.StartsWith("description:")) desc = line.Substring(12).Trim();
                }
            }
        }
        catch { }
    }
    static bool IsUnder(string path, string root)
    {
        try { return Path.GetFullPath(path).StartsWith(Path.GetFullPath(root), StringComparison.OrdinalIgnoreCase); }
        catch { return false; }
    }
    // rounded-rectangle path (4 arcs)
    static GraphicsPath RoundedPath(Rectangle r, int rad)
    {
        var p = new GraphicsPath();
        int d = rad * 2;
        if (rad <= 0 || d > r.Width || d > r.Height) { p.AddRectangle(r); return p; }
        p.AddArc(r.X, r.Y, d, d, 180, 90);
        p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }
    static Color Lerp(Color a, Color b, float t)
    {
        return Color.FromArgb(
            (int)(a.R + (b.R - a.R) * t),
            (int)(a.G + (b.G - a.G) * t),
            (int)(a.B + (b.B - a.B) * t));
    }
    static bool NearColor(Color a, Color b)
    {
        return Math.Abs(a.R - b.R) <= 2 && Math.Abs(a.G - b.G) <= 2 && Math.Abs(a.B - b.B) <= 2;
    }
    // give a control a rounded, self-maintaining Region (floating-card look)
    static void RoundRegion(Control c, int rad)
    {
        EventHandler apply = (s, e) => { try { if (c.Width > 0 && c.Height > 0) c.Region = new Region(RoundedPath(new Rectangle(0, 0, c.Width, c.Height), rad)); } catch { } };
        c.Resize += apply;
        apply(null, null);
    }
    // rounded button + smooth animated hover fade
    void Hoverize(Button b, Color normal, Color hover)
    {
        b.FlatStyle = FlatStyle.Flat;
        b.FlatAppearance.BorderSize = 0;
        b.FlatAppearance.MouseOverBackColor = hover;
        b.FlatAppearance.MouseDownBackColor = hover;
        b.BackColor = normal;
        b.Cursor = Cursors.Hand;
        RoundRegion(b, 10);
        var timer = new System.Windows.Forms.Timer { Interval = 15 };
        bool over = false;
        timer.Tick += (s, e) =>
        {
            Color target = over ? hover : normal;
            Color next = Lerp(b.BackColor, target, 0.30f);
            if (NearColor(next, target)) { b.BackColor = target; timer.Stop(); }
            else b.BackColor = next;
        };
        b.MouseEnter += (s, e) => { over = true; timer.Start(); };
        b.MouseLeave += (s, e) => { over = false; timer.Start(); };
    }

    // ---------- button factories (one look, defined once) ----------
    static readonly Color GhostHover  = Color.FromArgb(70, 70, 78);
    static readonly Color DangerFill  = Color.FromArgb(150, 70, 70);
    static readonly Color DangerHover = Color.FromArgb(170, 84, 84);
    static readonly Color OkFill      = Color.FromArgb(70, 120, 85);
    static readonly Color OkHover     = Color.FromArgb(84, 140, 100);

    Button GhostBtn(string text)
    {
        var b = new Button { Text = text, FlatStyle = FlatStyle.Flat, ForeColor = Color.White };
        Hoverize(b, Panel2, GhostHover);
        return b;
    }
    Button DangerBtn(string text)
    {
        var b = new Button { Text = text, FlatStyle = FlatStyle.Flat, ForeColor = Color.White };
        Hoverize(b, DangerFill, DangerHover);
        return b;
    }
    Button OkBtn(string text)
    {
        var b = new Button { Text = text, FlatStyle = FlatStyle.Flat, ForeColor = Color.White };
        Hoverize(b, OkFill, OkHover);
        return b;
    }
    Button AccentBtn(string text)
    {
        var b = new Button { Text = text, FlatStyle = FlatStyle.Flat, ForeColor = Color.Black,
            Font = new Font("Segoe UI", 10f, FontStyle.Bold) };
        Hoverize(b, Accent, AccentHi);
        return b;
    }

    // ---------- recents + settings ----------
    List<string> GetRecent()
    {
        var list = new List<string>();
        try { if (File.Exists(RecentFile)) foreach (var l in File.ReadAllLines(RecentFile))
            if (l.Length > 0 && Directory.Exists(l) && !list.Contains(l)) list.Add(l); }
        catch { }
        return list;
    }
    void SaveRecent(string path)
    {
        var list = new List<string> { path };
        foreach (var r in GetRecent()) if (r != path && !list.Contains(r)) list.Add(r);
        if (list.Count > 15) list = list.GetRange(0, 15);
        try { File.WriteAllLines(RecentFile, list.ToArray()); } catch { }
    }
    void LoadSettings()
    {
        try
        {
            if (!File.Exists(SettingsFile)) return;
            loadingSettings = true;
            string legacyModel = null;
            bool foundClaudeModel = false, foundCodexModel = false;
            foreach (var line in File.ReadAllLines(SettingsFile))
            {
                if (line.StartsWith("agent="))
                {
                    var v = line.Substring(6);
                    if (v == "Claude" || v == "Codex")
                    {
                        if (agentCombo != null) agentCombo.SelectedItem = v;
                        if (termAgentCombo != null) termAgentCombo.SelectedItem = v;
                    }
                }
                else if (line.StartsWith("model=")) { var v = line.Substring(6); if (v.Length > 0) { legacyModel = v; modelCombo.Text = v; } }
                else if (line.StartsWith("claudeModel=")) { var v = line.Substring(12); if (v.Length > 0) { claudeLaunchModel = v; foundClaudeModel = true; } }
                else if (line.StartsWith("codexModel=")) { var v = line.Substring(11); if (v.Length > 0) { codexLaunchModel = v; foundCodexModel = true; } }
                else if (line.StartsWith("headroom=")) hrCheck.Checked = line.Substring(9).Trim() == "1";
                else if (line.StartsWith("cont=")) continueChk.Checked = line.Substring(5).Trim() == "1";
                else if (line.StartsWith("extra=")) { if (extraBox != null) extraBox.Text = line.Substring(6); }
                else if (line.StartsWith("perm="))
                {
                    string v = line.Substring(5);
                    for (int i = 0; i < permCombo.Items.Count; i++)
                        if ((string)permCombo.Items[i] == v) { permCombo.SelectedIndex = i; break; }
                }
            }
            string agent = ActiveLaunchAgent();
            if (legacyModel != null)
            {
                if (agent == "Codex" && !foundCodexModel) codexLaunchModel = legacyModel;
                else if (!foundClaudeModel) claudeLaunchModel = legacyModel;
            }
            activeModelAgent = agent;
            loadingSettings = false;
            RefreshModelChoicesForAgent();
        }
        catch { loadingSettings = false; }
    }
    void SaveSettings()
    {
        try
        {
            string currentAgent = ActiveLaunchAgent();
            RememberVisibleModelForAgent(currentAgent);
            string currentModel = modelCombo != null ? modelCombo.Text.Trim() : StoredModelForAgent(currentAgent);
            string perm = (permCombo != null && permCombo.SelectedItem != null) ? permCombo.SelectedItem.ToString() : "";
            string extra = extraBox != null ? extraBox.Text.Trim() : "";
            File.WriteAllLines(SettingsFile, new[] {
                "agent=" + currentAgent,
                "model=" + currentModel,
                "claudeModel=" + claudeLaunchModel,
                "codexModel=" + codexLaunchModel,
                "headroom=" + ((hrCheck != null && hrCheck.Checked) ? "1" : "0"),
                "perm=" + perm,
                "cont=" + ((continueChk != null && continueChk.Checked) ? "1" : "0"),
                "extra=" + extra
            });
        }
        catch { }
    }

    // ---------- launch ----------
    bool EnsureProxy()
    {
        if (TestPort(ProxyPort)) return true;
        try { Process.Start(new ProcessStartInfo("headroom", "proxy") { WindowStyle = ProcessWindowStyle.Minimized, UseShellExecute = true }); }
        catch
        {
            MessageBox.Show("Headroom is not installed / not on PATH.\n\nInstall it, or uncheck 'Route through Headroom'.",
                "Hydra", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return false;
        }
        for (int i = 0; i < 20; i++) { Thread.Sleep(500); if (TestPort(ProxyPort)) return true; }
        MessageBox.Show("Started 'headroom proxy' but port " + ProxyPort + " did not come up in time.",
            "Hydra", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        return false;
    }
    // ---------- caveman (output compression, a global Claude Code plugin) ----------
    static bool CavemanInstalled()
    {
        try
        {
            // Plugin install (installed_plugins.json) …
            if (File.Exists(PluginsFile) && File.ReadAllText(PluginsFile).IndexOf("caveman", StringComparison.OrdinalIgnoreCase) >= 0) return true;
            // … or the standalone-hooks fallback the installer uses when the plugin path isn't
            // available (e.g. claude not yet on PATH): it wires ~/.claude/hooks/caveman-*.js.
            if (File.Exists(Path.Combine(HomeDir, ".claude", "hooks", "caveman-config.js"))) return true;
            if (File.Exists(ClaudeSettings) && File.ReadAllText(ClaudeSettings).IndexOf("caveman", StringComparison.OrdinalIgnoreCase) >= 0) return true;
            if (File.Exists(CodexAgents) && File.ReadAllText(CodexAgents).IndexOf("claude-manager-caveman-codex", StringComparison.OrdinalIgnoreCase) >= 0) return true;
        }
        catch { }
        return false;
    }

    // Robust Claude CLI install. 1) Anthropic's official self-contained installer (PowerShell,
    // no npm). 2) If claude still isn't found, npm into a USER-WRITABLE prefix we own
    // (%USERPROFILE%\.claude-manager\bin, already first on PATH) with a fresh cache — dodges a
    // root/admin-owned global prefix (EACCES) and a poisoned npm cache (EEXIST). No admin needed.
    static string ClaudeInstallCmd()
    {
        return "powershell -NoProfile -Command \"irm https://claude.ai/install.ps1 | iex\" "
             + "|| npm install -g @anthropic-ai/claude-code@latest "
             + "--prefix \"%USERPROFILE%\\.claude-manager\\bin\" --cache \"%TEMP%\\cmnpm%RANDOM%\" --no-fund --no-audit --force";
    }
    static string CodexInstallCmd()
    {
        return "npm install -g @openai/codex@latest "
             + "--prefix \"%USERPROFILE%\\.claude-manager\\bin\" --cache \"%TEMP%\\cmnpm%RANDOM%\" --no-fund --no-audit --force";
    }
    void UpdateCavemanStatus()
    {
        bool on = CavemanInstalled();
        suppressCaveman = true; cvCheck.Checked = on; suppressCaveman = false;
        if (on) { cvStatus.Text = "● installed — Claude/Codex talk terse every session"; cvStatus.ForeColor = Green; }
        else    { cvStatus.Text = "○ not installed — tick to add (needs Node 18+)"; cvStatus.ForeColor = Yellow; }
        UpdateCompressionAdvisory();
    }
    void SetCaveman(bool install)
    {
        if (!OnPath("npx.exe") && !OnPath("npx.cmd") && !OnPath("npx"))
        {
            MessageBox.Show("npx not found. Install Node.js 18+ (nodejs.org) then try again.",
                "Hydra", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            UpdateCavemanStatus(); return;
        }
        string verb = install ? "Install" : "Remove";
        if (MessageBox.Show(verb + " Caveman for Claude Code and Codex CLI?\n\nThis is a global change to every Claude/Codex session on this machine.\nCaveman shrinks agent replies (~65% fewer output tokens).",
                "Hydra", MessageBoxButtons.OKCancel, MessageBoxIcon.Question) != DialogResult.OK)
        { UpdateCavemanStatus(); return; }

        cvStatus.Text = (install ? "installing" : "removing") + " Caveman… (app stays usable)"; cvStatus.ForeColor = Yellow;
        cvCheck.Enabled = false;   // background install: only the toggle locks, not the whole app
        var th = new Thread(() =>
        {
            string err = null;
            try
            {
                string args = "-y github:JuliusBrussee/caveman --only claude --only codex" + (install ? "" : " --uninstall");
                var psi = new ProcessStartInfo("npx", args) { UseShellExecute = false, CreateNoWindow = true,
                    RedirectStandardOutput = true, RedirectStandardError = true };
                var p = Process.Start(psi);
                p.StandardOutput.ReadToEnd(); p.StandardError.ReadToEnd();
                p.WaitForExit(120000);
                if (install) { EnsureCodexCavemanInstructions(); InstallBundledCavemanForCodexIfPossible(); }
            }
            catch (Exception ex) { err = ex.Message; }
            try { BeginInvoke((Action)(() =>
            {
                cvCheck.Enabled = true;
                if (err != null) MessageBox.Show("Caveman " + verb.ToLower() + " failed:\n" + err, "Hydra");
                UpdateCavemanStatus(); UpdateLaunchText();
            })); } catch { }
        });
        th.IsBackground = true; th.Start();
    }

    // ---------- rtk (input compression via a global Claude Code PreToolUse hook) ----------
    static bool RtkInstalled()
    {
        try {
            bool claude = File.Exists(ClaudeSettings) && File.ReadAllText(ClaudeSettings).IndexOf("rtk hook", StringComparison.OrdinalIgnoreCase) >= 0;
            bool codex = File.Exists(CodexRtk) && File.Exists(CodexAgents) && File.ReadAllText(CodexAgents).IndexOf("RTK.md", StringComparison.OrdinalIgnoreCase) >= 0;
            return claude || codex;
        }
        catch { return false; }
    }
    void UpdateRtkStatus()
    {
        bool on = RtkInstalled();
        suppressRtk = true; rtCheck.Checked = on; suppressRtk = false;
        if (on) { rtStatus.Text = "● installed — shell/test/build output filtered before it hits context"; rtStatus.ForeColor = Green; }
        else    { rtStatus.Text = "○ not installed — tick to add (needs rtk on PATH)"; rtStatus.ForeColor = Yellow; }
        UpdateCompressionAdvisory();
    }
    void SetRtk(bool install)
    {
        if (!OnPath("rtk.exe") && !OnPath("rtk"))
        {
            MessageBox.Show("rtk is not on your PATH.\n\nInstall it first (run INSTALL-Windows.bat, or drop rtk.exe in ~\\.local\\bin), then try again.",
                "Hydra", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            UpdateRtkStatus(); return;
        }
        string verb = install ? "Install" : "Remove";
        if (MessageBox.Show(verb + " RTK for Claude Code and Codex CLI?\n\nGlobal change: Claude gets a shell hook; Codex gets global AGENTS.md instructions to prefix shell commands with rtk.",
                "Hydra", MessageBoxButtons.OKCancel, MessageBoxIcon.Question) != DialogResult.OK)
        { UpdateRtkStatus(); return; }

        rtStatus.Text = (install ? "installing" : "removing") + " RTK hook… (app stays usable)"; rtStatus.ForeColor = Yellow;
        rtCheck.Enabled = false;
        var th = new Thread(() =>
        {
            string err = null;
            try
            {
                string args = install ? "init -g --auto-patch" : "init -g --uninstall";
                var psi = new ProcessStartInfo("rtk", args) { UseShellExecute = false, CreateNoWindow = true,
                    RedirectStandardOutput = true, RedirectStandardError = true };
                var p = Process.Start(psi);
                p.StandardOutput.ReadToEnd(); p.StandardError.ReadToEnd();
                p.WaitForExit(60000);
                if (install)
                    RunLoggedCmd("rtk init -g --codex");
                else
                    RunLoggedCmd("rtk init -g --codex --uninstall");
            }
            catch (Exception ex) { err = ex.Message; }
            try { BeginInvoke((Action)(() =>
            {
                rtCheck.Enabled = true;
                if (err != null) MessageBox.Show("RTK " + verb.ToLower() + " failed:\n" + err, "Hydra");
                UpdateRtkStatus(); UpdateLaunchText();
            })); } catch { }
        });
        th.IsBackground = true; th.Start();
    }

    // RTK (input) + Caveman (output) are the recommended default combo — non-overlapping.
    // On the very first run, quietly turn them on if their binaries are present but the
    // tools aren't active yet. Headroom is left off by default (it overlaps RTK on shell output).
    void EnsureDefaultCompression(bool firstRun)
    {
        if (!firstRun) return;
        QuietEnableRtk();
        QuietEnableCaveman();
        QuietInstallBundledSkills();
        try { SaveSettings(); } catch { }   // create settings file so this only runs once
    }

    // Ship bundled skills as a native default for Claude and ChatGPT/Codex.
    void QuietInstallBundledSkills()
    {
        try
        {
            bool codexHasSkills = Directory.Exists(CodexSkillsDir) && Directory.GetFiles(CodexSkillsDir, "SKILL.md", SearchOption.AllDirectories).Length > 0;
            if (CountSkills() > 0 && codexHasSkills) return;
            string src = FindSkillsSource();
            if (src == null) return;
            var th = new Thread(() => { try { DoInstallSkills(src); } catch { } });
            th.IsBackground = true; th.Start();
        }
        catch { }
    }

    void QuietEnableRtk()
    {
        try
        {
            if (RtkInstalled()) return;
            if (!OnPath("rtk.exe") && !OnPath("rtk")) return;
            var psi = new ProcessStartInfo("rtk", "init -g --auto-patch")
            { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
            var p = Process.Start(psi);
            p.StandardOutput.ReadToEnd(); p.StandardError.ReadToEnd();
            p.WaitForExit(30000);
            RunLoggedCmd("rtk init -g --codex");
        }
        catch { }
        UpdateRtkStatus();
        UpdateLaunchText();
    }

    void QuietEnableCaveman()
    {
        if (CavemanInstalled()) return;
        if (!OnPath("npx.exe") && !OnPath("npx.cmd") && !OnPath("npx")) return;
        if (cvStatus != null) { cvStatus.Text = "enabling Caveman by default…"; cvStatus.ForeColor = Yellow; }
        var th = new Thread(() =>
        {
            try
            {
                var psi = new ProcessStartInfo("npx", "-y github:JuliusBrussee/caveman --only claude --only codex")
                { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
                var p = Process.Start(psi);
                p.StandardOutput.ReadToEnd(); p.StandardError.ReadToEnd();
                p.WaitForExit(120000);
                EnsureCodexCavemanInstructions();
                InstallBundledCavemanForCodexIfPossible();
            }
            catch { }
            try { BeginInvoke((Action)(() => { UpdateCavemanStatus(); UpdateLaunchText(); UpdateCompressionAdvisory(); })); } catch { }
        });
        th.IsBackground = true; th.Start();
    }

    string PermFlag()
    {
        string p = (permCombo.SelectedItem as string) ?? "";
        if (p.StartsWith("Bypass")) return " --dangerously-skip-permissions";
        if (p.StartsWith("Plan")) return " --permission-mode plan";
        if (p.StartsWith("Accept")) return " --permission-mode acceptEdits";
        return "";
    }
    string CodexPermFlag()
    {
        return " --dangerously-bypass-approvals-and-sandbox";
    }
    static string CliModelName(string selection)
    {
        string m = (selection ?? "").Trim();
        string key = m.ToLowerInvariant().Replace(" ", "").Replace("-", "");
        if (key == "fable" || key == "claudefable5") return "claude-fable-5";
        if (key == "opus" || key == "claudeopus48") return "claude-opus-4-8";
        if (key == "sonnet" || key == "claudesonnet5" || key == "claudesonnet46") return "claude-sonnet-5";
        if (key == "haiku" || key == "claudehaiku45" || key == "claudehaiku4520251001") return "claude-haiku-4-5";
        if (key == "chatgpt5.6" || key == "gpt5.6") return "gpt-5.6-sol";
        if (key == "chatgpt5.5") return "gpt-5.5";
        return m;
    }
    static bool ChoiceContains(object[] choices, string value)
    {
        foreach (object c in choices)
            if (string.Equals(c.ToString(), value, StringComparison.OrdinalIgnoreCase)) return true;
        return false;
    }
    string ActiveLaunchAgent()
    {
        return (agentCombo != null && agentCombo.SelectedItem != null) ? agentCombo.SelectedItem.ToString() : "Claude";
    }
    static object[] ChoicesForAgent(string agent)
    {
        return agent == "Codex" ? ChatGptModelChoices : ClaudeModelChoices;
    }
    static string NormalizeModelForAgent(string selection, string agent)
    {
        string m = CliModelName(selection);
        if (m.Length == 0 || string.Equals(m, "Default", StringComparison.OrdinalIgnoreCase)) return "Default";
        return ChoiceContains(ChoicesForAgent(agent), m) ? m : "Default";
    }
    void RememberVisibleModelForAgent(string agent)
    {
        if (modelCombo == null || refreshingModelChoices) return;
        string normalized = NormalizeModelForAgent(modelCombo.Text ?? "", agent);
        if (agent == "Codex") codexLaunchModel = normalized;
        else claudeLaunchModel = normalized;
    }
    string StoredModelForAgent(string agent)
    {
        return NormalizeModelForAgent(agent == "Codex" ? codexLaunchModel : claudeLaunchModel, agent);
    }
    void RefreshModelChoicesForAgent()
    {
        if (modelCombo == null) return;
        string agent = ActiveLaunchAgent();
        object[] choices = ChoicesForAgent(agent);
        string current = StoredModelForAgent(agent);
        refreshingModelChoices = true;
        modelCombo.BeginUpdate();
        modelCombo.Items.Clear();
        modelCombo.Items.AddRange(choices);
        modelCombo.EndUpdate();
        if (current.Length == 0 || string.Equals(current, "Default", StringComparison.OrdinalIgnoreCase))
            modelCombo.Text = "Default";
        else if (ChoiceContains(choices, current))
            modelCombo.Text = current;
        else
            modelCombo.Text = "Default";
        activeModelAgent = agent;
        refreshingModelChoices = false;
    }
    void RefreshSaasBuildModelChoices()
    {
        if (saasBuildModel == null) return;
        string agent = (saasBuildAgent != null && saasBuildAgent.SelectedItem != null) ? saasBuildAgent.SelectedItem.ToString() : "Claude";
        object[] choices = agent == "ChatGPT" ? ChatGptModelChoices : ClaudeModelChoices;
        string current = (saasBuildModel.Text ?? "").Trim();
        current = CliModelName(current);
        saasBuildModel.BeginUpdate();
        saasBuildModel.Items.Clear();
        saasBuildModel.Items.AddRange(choices);
        saasBuildModel.EndUpdate();
        if (current.Length == 0 || string.Equals(current, "Default", StringComparison.OrdinalIgnoreCase))
            saasBuildModel.Text = "Default";
        else if (ChoiceContains(choices, current))
            saasBuildModel.Text = current;
        else
            saasBuildModel.Text = "Default";
    }
    static string CmdQ(string s) { return "\"" + s.Replace("\"", "\\\"") + "\""; }
    int RunCodexCmd(string args)
    {
        return RunLoggedCmd("set \"CODEX_HOME=" + CodexDir + "\" && codex " + args);
    }
    static bool CodexMarketplaceConfigured(string name, string root)
    {
        try
        {
            string cfg = Path.Combine(CodexDir, "config.toml");
            if (!File.Exists(cfg)) return false;
            string text = File.ReadAllText(cfg);
            return text.IndexOf("[marketplaces." + name + "]", StringComparison.OrdinalIgnoreCase) >= 0
                && text.IndexOf("source = \"" + root + "\"", StringComparison.OrdinalIgnoreCase) >= 0;
        }
        catch { return false; }
    }
    static string CodexCavemanBlock()
    {
        return "\r\n<!-- claude-manager-caveman-codex -->\r\n"
             + "# Caveman Mode\r\n\r\n"
             + "Respond terse like smart caveman. Keep all technical substance, code, commands, API names, errors, security warnings, and irreversible-action warnings precise. "
             + "Drop filler, pleasantries, hedging, and repetition. Use normal technical English for code, commits, diffs, legal/security risk, or when terse fragments could confuse. "
             + "Resume terse mode after the risky/precise part. Stop only when user says \"stop caveman\" or \"normal mode\".\r\n"
             + "<!-- /claude-manager-caveman-codex -->\r\n";
    }
    static void EnsureCodexCavemanInstructions()
    {
        try
        {
            Directory.CreateDirectory(CodexDir);
            string start = "<!-- claude-manager-caveman-codex -->";
            string end = "<!-- /claude-manager-caveman-codex -->";
            string text = File.Exists(CodexAgents) ? File.ReadAllText(CodexAgents) : "";
            string block = CodexCavemanBlock();
            int si = text.IndexOf(start, StringComparison.OrdinalIgnoreCase);
            if (si >= 0)
            {
                int ei = text.IndexOf(end, si, StringComparison.OrdinalIgnoreCase);
                if (ei >= 0) text = text.Substring(0, si) + block + text.Substring(ei + end.Length);
            }
            else text = text.Trim() + block;
            File.WriteAllText(CodexAgents, text.Trim() + "\r\n");
        }
        catch { }
    }
    void InstallBundledCavemanForCodexIfPossible()
    {
        try
        {
            if (!HasCodex()) return;
            string marker = Path.Combine(StateDir, ".codex-caveman-installed");
            string src = FindToolsSource();
            if (src == null) return;
            string root = Path.Combine(src, "caveman");
            if (!File.Exists(Path.Combine(root, ".agents", "plugins", "marketplace.json"))) return;
            if (!CodexMarketplaceConfigured("caveman", root))
            {
                RunCodexCmd("plugin marketplace remove caveman");
                RunCodexCmd("plugin marketplace add " + CmdQ(root));
            }
            int plugin = RunCodexCmd("plugin add caveman@caveman");
            if (plugin == 0) File.WriteAllText(marker, "");
        }
        catch { }
    }
    void EnsureCodexCompressionForLaunch(bool useRtk, bool useCaveman)
    {
        if (useRtk && HasRtk()) RunLoggedCmd("rtk init -g --codex");
        if (useCaveman)
        {
            EnsureCodexCavemanInstructions();
            InstallBundledCavemanForCodexIfPossible();
        }
    }
    void StartClaude(string folder)
    {
        if (string.IsNullOrWhiteSpace(folder) || !Directory.Exists(folder))
        {
            MessageBox.Show("Folder not found:\n" + folder, "Hydra", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return;
        }
        // The big "Launch Claude" button embeds the session as a tab INSIDE the manager
        // (same conhost-reparenting path as the Terminals tab), never an external window.
        SelectNav(0);              // Workspace tab: the session embeds on the right, in view
        NewTerminal(folder);       // embedded conhost session (handles Headroom/model/flags + SaveRecent)
        SaveSettings();
        RefreshRecent();
        UpdateProxyStatus();
    }

    // ---------- skills ----------
    void LoadSkills()
    {
        skillsList.BeginUpdate();
        skillsList.Items.Clear();
        int en = 0, dis = 0;
        AddSkillDir(SkillsDir, "Enabled", ref en);
        AddSkillDir(DisabledDir, "Disabled", ref dis);
        skillsList.EndUpdate();
        skillsCount.Text = en + " enabled" + (dis > 0 ? "  •  " + dis + " disabled" : "");
        UpdateSidebarCounts();
    }
    void AddSkillDir(string root, string status, ref int count)
    {
        if (!Directory.Exists(root)) return;
        foreach (var dir in Directory.GetDirectories(root))
        {
            string md = Path.Combine(dir, "SKILL.md");
            if (!File.Exists(md)) continue;
            string nm, ds; ReadMeta(md, out nm, out ds);
            var item = new ListViewItem(new DirectoryInfo(dir).Name) { Tag = dir };
            item.SubItems.Add(status);
            item.SubItems.Add(ds);
            if (status == "Disabled") item.ForeColor = TextFaint;
            skillsList.Items.Add(item);
            count++;
        }
    }
    ListViewItem SelectedSkill() { return skillsList.SelectedItems.Count > 0 ? skillsList.SelectedItems[0] : null; }
    void AddSkill()
    {
        using (var dlg = new FolderBrowserDialog { Description = "Pick a folder with SKILL.md (or a pack of skills)", ShowNewFolderButton = false })
        {
            if (dlg.ShowDialog() != DialogResult.OK) return;
            string[] found;
            try { found = Directory.GetFiles(dlg.SelectedPath, "SKILL.md", SearchOption.AllDirectories); }
            catch (Exception ex) { MessageBox.Show("Scan failed:\n" + ex.Message, "Hydra"); return; }
            if (found.Length == 0) { MessageBox.Show("No SKILL.md found in that folder.", "Hydra", MessageBoxButtons.OK, MessageBoxIcon.Warning); return; }
            Directory.CreateDirectory(SkillsDir);
            Directory.CreateDirectory(CodexSkillsDir);
            int n = 0;
            foreach (var md in found)
            {
                string nm, ds; ReadMeta(md, out nm, out ds);
                string src = Path.GetDirectoryName(md);
                if (string.IsNullOrEmpty(nm)) nm = new DirectoryInfo(src).Name;
                bool copied = false;
                try { CopyDir(src, Path.Combine(SkillsDir, nm)); copied = true; } catch { }
                try { CopyDir(src, Path.Combine(CodexSkillsDir, nm)); copied = true; } catch { }
                if (copied) n++;
            }
            MessageBox.Show("Imported " + n + " skill(s) for Claude and ChatGPT/Codex.", "Hydra");
            LoadSkills();
        }
    }
    void RemoveSkill()
    {
        var it = SelectedSkill(); if (it == null) return;
        string dir = (string)it.Tag;
        if (MessageBox.Show("Delete skill '" + new DirectoryInfo(dir).Name + "'?\n\n" + dir, "Hydra",
                MessageBoxButtons.YesNo, MessageBoxIcon.Warning) != DialogResult.Yes) return;
        try { Directory.Delete(dir, true); } catch (Exception ex) { MessageBox.Show("Delete failed:\n" + ex.Message, "Hydra"); }
        try { Directory.Delete(Path.Combine(CodexSkillsDir, new DirectoryInfo(dir).Name), true); } catch { }
        try { Directory.Delete(Path.Combine(CodexDisabledDir, new DirectoryInfo(dir).Name), true); } catch { }
        LoadSkills();
    }
    void ToggleSkill()
    {
        var it = SelectedSkill(); if (it == null) return;
        string dir = (string)it.Tag;
        string name = new DirectoryInfo(dir).Name;
        bool enabled = IsUnder(dir, SkillsDir);
        string destRoot = enabled ? DisabledDir : SkillsDir;
        Directory.CreateDirectory(destRoot);
        string target = Path.Combine(destRoot, name);
        if (Directory.Exists(target)) { MessageBox.Show("A skill named '" + name + "' already exists on the other side.", "Hydra"); return; }
        try { Directory.Move(dir, target); } catch (Exception ex) { MessageBox.Show("Move failed:\n" + ex.Message, "Hydra"); }
        string codexSrc = Path.Combine(enabled ? CodexSkillsDir : CodexDisabledDir, name);
        string codexDestRoot = enabled ? CodexDisabledDir : CodexSkillsDir;
        string codexTarget = Path.Combine(codexDestRoot, name);
        try
        {
            Directory.CreateDirectory(codexDestRoot);
            if (Directory.Exists(codexSrc) && !Directory.Exists(codexTarget)) Directory.Move(codexSrc, codexTarget);
        }
        catch { }
        LoadSkills();
    }
    void OpenSkillsFolder() { try { Directory.CreateDirectory(SkillsDir); Process.Start(SkillsDir); } catch { } }

    // ---------- glossary ----------
    class GEntry { public string Cat, Term, Desc; public GEntry(string c, string t, string d) { Cat = c; Term = t; Desc = d; } }
    List<GEntry> BuildGlossary()
    {
        var g = new List<GEntry>();
        string S = "Slash commands (in session)";
        g.Add(new GEntry(S, "/help", "List all commands and shortcuts."));
        g.Add(new GEntry(S, "/clear", "Clear the conversation and free up context."));
        g.Add(new GEntry(S, "/compact", "Summarize & compress the conversation to save context."));
        g.Add(new GEntry(S, "/config", "Open settings (theme, model, editor, verbosity)."));
        g.Add(new GEntry(S, "/model", "Switch the model for this session (Opus / Sonnet / Haiku)."));
        g.Add(new GEntry(S, "/agents", "Create and manage custom subagents."));
        g.Add(new GEntry(S, "/mcp", "Manage MCP servers and inspect their tools."));
        g.Add(new GEntry(S, "/init", "Generate a CLAUDE.md documenting the codebase."));
        g.Add(new GEntry(S, "/memory", "View/edit memory files. Tip: start a line with # to save a memory."));
        g.Add(new GEntry(S, "/permissions", "View or edit tool permission rules."));
        g.Add(new GEntry(S, "/review", "Review a pull request."));
        g.Add(new GEntry(S, "/security-review", "Scan current changes for vulnerabilities."));
        g.Add(new GEntry(S, "/loop", "Run a prompt/command on a repeat, e.g. /loop 5m /babysit-prs. Omit interval to self-pace."));
        g.Add(new GEntry(S, "/goal", "Set a goal; a Stop hook keeps the session working until the condition is met."));
        g.Add(new GEntry(S, "/vim", "Toggle vim keybindings in the prompt editor."));
        g.Add(new GEntry(S, "/fast", "Toggle Fast mode (faster Opus output; Opus 4.7/4.8)."));
        g.Add(new GEntry(S, "/resume", "Resume a previous conversation/session."));
        g.Add(new GEntry(S, "/status", "Show account, model, and connection status."));
        g.Add(new GEntry(S, "/cost", "Show token usage and cost for the session."));
        g.Add(new GEntry(S, "/doctor", "Diagnose installation and health issues."));
        g.Add(new GEntry(S, "/login  •  /logout", "Sign in / switch account, or sign out."));
        g.Add(new GEntry(S, "/terminal-setup", "Enable Shift+Enter for newlines and other keybindings."));
        g.Add(new GEntry(S, "/bug", "Report a bug to Anthropic."));
        g.Add(new GEntry(S, "/<skill-name>", "Invoke an installed skill, e.g. /stop-slop, /code-review, /verify."));

        string F = "CLI flags (at startup)";
        g.Add(new GEntry(F, "claude", "Start an interactive session in the current folder."));
        g.Add(new GEntry(F, "-p, --print \"...\"", "Run once, print the result, and exit (great for scripting)."));
        g.Add(new GEntry(F, "-c, --continue", "Continue the most recent conversation."));
        g.Add(new GEntry(F, "--resume", "Pick a past session to resume."));
        g.Add(new GEntry(F, "--model <alias|id>", "Choose a current Claude model, e.g. claude-fable-5, claude-opus-4-8, claude-sonnet-5, or claude-haiku-4-5."));
        g.Add(new GEntry(F, "--dangerously-skip-permissions", "Bypass ALL permission prompts. Fast, but runs anything without asking."));
        g.Add(new GEntry(F, "--permission-mode <mode>", "default | plan | acceptEdits | bypassPermissions."));
        g.Add(new GEntry(F, "--effort <level>", "Set reasoning effort for the session."));
        g.Add(new GEntry(F, "--agent <name>", "Start with a specific subagent."));
        g.Add(new GEntry(F, "--add-dir <dirs...>", "Allow tools to access extra directories."));
        g.Add(new GEntry(F, "--mcp-config <files...>", "Load MCP servers from JSON config files."));
        g.Add(new GEntry(F, "--ide", "Auto-connect to your IDE on startup."));
        g.Add(new GEntry(F, "--bg, --background", "Start as a background agent."));
        g.Add(new GEntry(F, "--debug", "Enable debug logging."));
        g.Add(new GEntry(F, "--append-system-prompt \"...\"", "Append text to the default system prompt."));

        string X = "Codex CLI";
        g.Add(new GEntry(X, "codex", "Start an interactive ChatGPT/Codex coding session in the current folder."));
        g.Add(new GEntry(X, "codex -C <dir>", "Start Codex with an explicit working root. Hydra uses this for every Codex terminal."));
        g.Add(new GEntry(X, "--model <id>", "Choose a Codex model, e.g. gpt-5.6-sol, gpt-5.6-terra, or gpt-5.6-luna."));
        g.Add(new GEntry(X, "--dangerously-bypass-approvals-and-sandbox", "YOLO mode: no approvals and no sandbox. Hydra starts Codex terminals this way."));
        g.Add(new GEntry(X, "--ask-for-approval <policy>", "Approval policy for Codex when not using YOLO: untrusted, on-request, or never."));
        g.Add(new GEntry(X, "--sandbox <mode>", "Codex sandbox mode: read-only, workspace-write, or danger-full-access."));
        g.Add(new GEntry(X, "resume --last", "Resume the most recent Codex conversation."));
        g.Add(new GEntry(X, "codex plugin list", "Show installed Codex plugins and their enabled/installed status."));
        g.Add(new GEntry(X, "codex plugin marketplace add <path>", "Register a local Codex plugin marketplace, like the bundled Caveman marketplace."));
        g.Add(new GEntry(X, "codex plugin add caveman@caveman", "Install Caveman from the local marketplace for Codex sessions."));
        g.Add(new GEntry(X, "~/.codex/AGENTS.md", "Global Codex instructions. Hydra writes RTK/Caveman guidance here."));
        g.Add(new GEntry(X, "~/.agents/skills", "Codex/ChatGPT user skills folder. Hydra mirrors bundled/imported skills here."));
        g.Add(new GEntry(X, "rtk init -g --codex", "Install RTK guidance for Codex so shell commands use token-filtered rtk output."));
        g.Add(new GEntry(X, "CODEX_HOME", "Points Codex at its config/state directory; Hydra sets it to ~/.codex."));

        string K = "Keyboard & prompt tips";
        g.Add(new GEntry(K, "Esc", "Interrupt Claude / cancel the current action."));
        g.Add(new GEntry(K, "Esc  Esc", "Rewind — edit a previous message and branch."));
        g.Add(new GEntry(K, "Shift+Tab", "Cycle permission mode (auto-accept edits / plan mode)."));
        g.Add(new GEntry(K, "Shift+Enter", "Insert a newline (after running /terminal-setup)."));
        g.Add(new GEntry(K, "#  <text>", "Save a memory for future sessions."));
        g.Add(new GEntry(K, "!  <command>", "Run a shell command directly (bash mode)."));
        g.Add(new GEntry(K, "@  <path>", "Reference/attach a file or folder in your prompt."));
        g.Add(new GEntry(K, "Ctrl+V", "Paste an image into the prompt."));
        g.Add(new GEntry(K, "Up arrow", "Cycle through previous prompt history."));

        string M = "Hydra (this app)";
        g.Add(new GEntry(M, "Ctrl+1 … Ctrl+5", "Switch tabs (Workspace / Settings / SaaS / Skills / Glossary)."));
        g.Add(new GEntry(M, "Ctrl+T", "Open a new embedded Claude terminal in the current folder."));
        g.Add(new GEntry(M, "Ctrl+W", "Close the selected terminal session."));
        g.Add(new GEntry(M, "Double-click title bar", "Maximize / restore the window. Drag edges to resize."));

        string H = "Headroom (token compression)";
        g.Add(new GEntry(H, "headroom proxy", "Start the compression proxy on port 8787."));
        g.Add(new GEntry(H, "headroom mcp install", "Register Headroom as an MCP server for Claude."));
        g.Add(new GEntry(H, "headroom wrap claude", "Durably route Claude Code through Headroom."));
        g.Add(new GEntry(H, "headroom savings", "Show measured token savings over time."));
        g.Add(new GEntry(H, "headroom dashboard", "Open the savings dashboard in your browser."));
        g.Add(new GEntry(H, "ANTHROPIC_BASE_URL", "Point Claude at the proxy: http://127.0.0.1:8787 (this app sets it for you)."));

        string R = "RTK (input compression)";
        g.Add(new GEntry(R, "What it is", "A Rust CLI + PreToolUse hook that rewrites shell commands (git status -> rtk git status) and filters their output — 60-90% fewer INPUT tokens. Native Windows, <10ms. Only affects Bash tool calls, not Read/Grep/Glob."));
        g.Add(new GEntry(R, "rtk init -g", "Install the auto-rewrite hook for Claude Code (this app's toggle does it for you)."));
        g.Add(new GEntry(R, "rtk gain", "Show measured token savings + USD; add --graph / --daily / --history."));
        g.Add(new GEntry(R, "rtk discover", "Find missed savings opportunities in recent sessions."));
        g.Add(new GEntry(R, "rtk ls / read / grep / diff", "Token-optimized file & search commands you can call directly."));
        g.Add(new GEntry(R, "rtk test <cmd>", "Run any test command, keep failures only (~90% smaller)."));
        g.Add(new GEntry(R, "rtk init -g --uninstall", "Remove the hook (this app's toggle does it for you)."));

        string C = "Caveman (output compression)";
        g.Add(new GEntry(C, "What it is", "A plugin that makes Claude reply in terse 'caveman' style — ~65% fewer OUTPUT tokens, full accuracy. Complements Headroom (which compresses INPUT)."));
        g.Add(new GEntry(C, "/caveman [lite|full|ultra|wenyan]", "Turn on caveman speak for the session; pick how terse. Says 'normal mode' to stop."));
        g.Add(new GEntry(C, "/caveman-commit", "Write a Conventional Commit message, <=50 char subject."));
        g.Add(new GEntry(C, "/caveman-review", "One-line PR review comments, e.g. L42: bug: user null. Add guard."));
        g.Add(new GEntry(C, "/caveman-stats", "Show real token savings this session + lifetime + USD."));
        g.Add(new GEntry(C, "/caveman-compress <file>", "Rewrite a memory file (e.g. CLAUDE.md) into caveman-speak to save input tokens every session."));
        g.Add(new GEntry(C, "Install / Remove", "Toggle it in Settings, or run: npx -y github:JuliusBrussee/caveman --only claude --only codex"));
        string V = "Claude Video (/watch)";
        g.Add(new GEntry(V, "/watch <url-or-path> [question]", "Analyze a video URL or local video using captions, selected frames, and optional Whisper transcription."));
        g.Add(new GEntry(V, "tools/claude-video", "Bundled Hydra copy of bradautomates/claude-video. Hydra installs its watch skill for Claude and Codex."));
        g.Add(new GEntry(V, "%USERPROFILE%\\.claude\\skills\\watch", "Claude skill install path for /watch."));
        g.Add(new GEntry(V, "%USERPROFILE%\\.agents\\skills\\watch", "Codex/ChatGPT skill install path for /watch."));
        string A = "Agent Skills";
        g.Add(new GEntry(A, "tools/agent-skills", "Bundled Hydra copy of addyosmani/agent-skills with 24 production engineering workflow skills."));
        g.Add(new GEntry(A, "using-agent-skills", "Meta-skill that helps choose the right lifecycle skill for the task."));
        g.Add(new GEntry(A, "/spec /plan /build /test /review /ship", "Lifecycle commands provided by the Agent Skills plugin for Claude; the same skills are available to Codex from %USERPROFILE%\\.agents\\skills."));
        g.Add(new GEntry(A, "%USERPROFILE%\\.claude\\skills", "Hydra installs Agent Skills here for Claude."));
        g.Add(new GEntry(A, "%USERPROFILE%\\.agents\\skills", "Hydra installs Agent Skills here for ChatGPT/Codex."));
        return g;
    }
    void RenderGlossary(string filter)
    {
        filter = (filter ?? "").Trim().ToLowerInvariant();
        glossaryList.BeginUpdate();
        glossaryList.Items.Clear();
        glossaryList.Groups.Clear();
        var groups = new Dictionary<string, ListViewGroup>();
        foreach (var e in glossary)
        {
            if (filter.Length > 0 && (e.Term + " " + e.Desc).ToLowerInvariant().IndexOf(filter) < 0) continue;
            ListViewGroup grp;
            if (!groups.TryGetValue(e.Cat, out grp)) { grp = new ListViewGroup(e.Cat); groups[e.Cat] = grp; glossaryList.Groups.Add(grp); }
            var it = new ListViewItem(e.Term) { Group = grp };
            it.SubItems.Add(e.Desc);
            glossaryList.Items.Add(it);
        }
        glossaryList.EndUpdate();
    }

    // ---------- UI ----------
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int val, int size);

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        try { int pref = 2; DwmSetWindowAttribute(Handle, 33, ref pref, sizeof(int)); } catch { }
    }

    // ---- custom-chrome (frameless) window support: edge-resize, drag, taskbar-aware maximize ----
    [DllImport("user32.dll")] static extern bool ReleaseCapture();
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr wParam, IntPtr lParam);
    [StructLayout(LayoutKind.Sequential)] struct WPOINT { public int x, y; }
    [StructLayout(LayoutKind.Sequential)] struct MINMAXINFO { public WPOINT r, ptMaxSize, ptMaxPosition, ptMinTrackSize, ptMaxTrackSize; }
    const int WM_NCHITTEST = 0x0084, WM_GETMINMAXINFO = 0x0024, WM_NCLBUTTONDOWN = 0x00A1;
    const int HTCAPTION = 2, HTLEFT = 10, HTRIGHT = 11, HTTOP = 12, HTTOPLEFT = 13,
              HTTOPRIGHT = 14, HTBOTTOM = 15, HTBOTTOMLEFT = 16, HTBOTTOMRIGHT = 17;

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == WM_GETMINMAXINFO)
        {
            var mmi = (MINMAXINFO)Marshal.PtrToStructure(m.LParam, typeof(MINMAXINFO));
            var scr = Screen.FromHandle(Handle);
            mmi.ptMaxPosition.x = scr.WorkingArea.Left - scr.Bounds.Left;
            mmi.ptMaxPosition.y = scr.WorkingArea.Top - scr.Bounds.Top;
            mmi.ptMaxSize.x = scr.WorkingArea.Width;
            mmi.ptMaxSize.y = scr.WorkingArea.Height;
            mmi.ptMinTrackSize.x = MinimumSize.Width;
            mmi.ptMinTrackSize.y = MinimumSize.Height;
            Marshal.StructureToPtr(mmi, m.LParam, true);
            return;
        }
        base.WndProc(ref m);
        if (m.Msg == WM_NCHITTEST && WindowState == FormWindowState.Normal)
        {
            long lp = m.LParam.ToInt64();
            var p = PointToClient(new Point((short)(lp & 0xFFFF), (short)((lp >> 16) & 0xFFFF)));
            int g = 8, w = ClientSize.Width, h = ClientSize.Height;
            bool L = p.X <= g, R = p.X >= w - g, T = p.Y <= g, B = p.Y >= h - g;
            int hit = 0;
            if (T && L) hit = HTTOPLEFT; else if (T && R) hit = HTTOPRIGHT;
            else if (B && L) hit = HTBOTTOMLEFT; else if (B && R) hit = HTBOTTOMRIGHT;
            else if (L) hit = HTLEFT; else if (R) hit = HTRIGHT;
            else if (T) hit = HTTOP; else if (B) hit = HTBOTTOM;
            if (hit != 0) m.Result = (IntPtr)hit;
        }
    }

    void ToggleMaxRestore()
    {
        WindowState = WindowState == FormWindowState.Maximized ? FormWindowState.Normal : FormWindowState.Maximized;
        if (btnMax != null) { btnMax.Text = WindowState == FormWindowState.Maximized ? "❐" : "□"; btnMax.Invalidate(); }
    }

    void DragTitleBar()
    {
        if (WindowState == FormWindowState.Maximized) return;
        ReleaseCapture();
        SendMessage(Handle, WM_NCLBUTTONDOWN, (IntPtr)HTCAPTION, IntPtr.Zero);
    }

    static string AppDir { get { return AppDomain.CurrentDomain.BaseDirectory; } }
    // Icon/logo: disk file first (easy to reskin), else the copy embedded in the exe
    // (/resource at build time) so a standalone Hydra.exe is fully self-contained.
    static Stream EmbeddedRes(string name)
    {
        try { return System.Reflection.Assembly.GetExecutingAssembly().GetManifestResourceStream(name); }
        catch { return null; }
    }
    static Icon AppIcon()
    {
        try { return new Icon(Path.Combine(AppDir, "bot.ico")); } catch { }
        try { using (var s = EmbeddedRes("bot.ico")) { if (s != null) return new Icon(s); } } catch { }
        return null;
    }
    static Image AppImage()
    {
        try { return Image.FromFile(Path.Combine(AppDir, "bot.png")); } catch { }
        try
        {
            using (var s = EmbeddedRes("bot.png"))
                if (s != null) using (var tmp = new Bitmap(s)) return new Bitmap(tmp); // deep copy: GDI+ needs the stream alive otherwise
        }
        catch { }
        return null;
    }

    void BuildOllamaControls(Panel host, int top)
    {
        ollamaButton = new Button {
            Text = "▶   Start Ollama", Location = new Point(8, top), Size = new Size(174, 36),
            FlatStyle = FlatStyle.Flat, BackColor = Color.FromArgb(25, 25, 29), ForeColor = TextDim,
            TextAlign = ContentAlignment.MiddleLeft, Padding = new Padding(10, 0, 0, 0),
            Font = new Font("Segoe UI Semibold", 9f, FontStyle.Bold), Cursor = Cursors.Hand, TabStop = true
        };
        ollamaButton.FlatAppearance.BorderSize = 0;
        ollamaButton.FlatAppearance.MouseOverBackColor = Field;
        ollamaButton.FlatAppearance.MouseDownBackColor = FieldHi;
        RoundRegion(ollamaButton, 8);
        ollamaButton.Click += (s, e) => ToggleOllama();
        host.Controls.Add(ollamaButton);

        sidebarOllamaDot = new Panel { Location = new Point(20, top + 44), Size = new Size(6, 6), BackColor = TextFaint };
        RoundRegion(sidebarOllamaDot, 3);
        host.Controls.Add(sidebarOllamaDot);
        ollamaStatus = new Label {
            Text = "Ollama · off", AutoEllipsis = true, Location = new Point(32, top + 39), Size = new Size(146, 17),
            ForeColor = TextFaint, Font = new Font("Segoe UI", 8f), TextAlign = ContentAlignment.MiddleLeft
        };
        host.Controls.Add(ollamaStatus);

        ollamaTerminalButton = new Button {
            Text = ">_  Open Ollama Terminal", Location = new Point(14, top + 60), Size = new Size(164, 25),
            FlatStyle = FlatStyle.Flat, BackColor = TitleBg, ForeColor = TextFaint,
            TextAlign = ContentAlignment.MiddleLeft, Font = new Font("Segoe UI", 8f), Cursor = Cursors.Hand, TabStop = true
        };
        ollamaTerminalButton.FlatAppearance.BorderSize = 0;
        ollamaTerminalButton.FlatAppearance.MouseOverBackColor = Field;
        ollamaTerminalButton.FlatAppearance.MouseDownBackColor = FieldHi;
        ollamaTerminalButton.Click += (s, e) => OpenOllamaTerminal();
        host.Controls.Add(ollamaTerminalButton);
    }

    void BuildSidebar(Panel host)
    {
        botLogo = new PictureBox { Location = new Point(14, 18), Size = new Size(30, 30),
            SizeMode = PictureBoxSizeMode.Zoom, BackColor = Color.Transparent, Image = AppImage() };
        RoundRegion(botLogo, 7);
        host.Controls.Add(botLogo);
        headerDot = new Panel { Location = new Point(38, 41), Size = new Size(7, 7), BackColor = Accent };
        RoundRegion(headerDot, 4);
        host.Controls.Add(headerDot);
        headerDot.BringToFront();

        var hTitle = new Label { Text = "Hydra", AutoSize = true, Location = new Point(54, 17),
            Font = new Font("Segoe UI Semibold", 10.5f, FontStyle.Bold), ForeColor = Color.White };
        host.Controls.Add(hTitle);
        var hVer = new Label { Text = "v1", AutoSize = true, UseMnemonic = false,
            Location = new Point(103, 20), Font = new Font("Segoe UI Semibold", 8f, FontStyle.Bold), ForeColor = Accent };
        host.Controls.Add(hVer);
        host.Controls.Add(new Label { Text = "By Ahmed Al-Eissa", AutoSize = true, Location = new Point(55, 36),
            ForeColor = TextFaint, Font = new Font("Segoe UI", 7.5f, FontStyle.Italic) });

        string[] titles = { "Workspace", "Settings", "SaaS", "Skills", "Glossary" };
        string[] icons = { ">_", "≡", "◇", "✦", "▤" };
        int navTop = 88;
        for (int i = 0; i < titles.Length; i++)
        {
            int idx = i;
            var nav = new Button {
                Text = icons[i] + "   " + titles[i], Location = new Point(8, navTop + i * 40), Size = new Size(174, 34),
                FlatStyle = FlatStyle.Flat, BackColor = TitleBg, ForeColor = TextDim,
                TextAlign = ContentAlignment.MiddleLeft, Padding = new Padding(10, 0, 0, 0),
                Font = new Font("Segoe UI", 9.5f), Cursor = Cursors.Hand, TabStop = true, Tag = false
            };
            nav.FlatAppearance.BorderSize = 0;
            nav.FlatAppearance.MouseOverBackColor = Field;
            nav.FlatAppearance.MouseDownBackColor = FieldHi;
            RoundRegion(nav, 8);
            nav.Paint += (s, e) => {
                if (nav.Tag is bool && (bool)nav.Tag)
                    using (var brush = new SolidBrush(Accent)) e.Graphics.FillRectangle(brush, 0, 7, 3, 20);
            };
            nav.Click += (s, e) => SelectNav(idx);
            host.Controls.Add(nav);
            navButtons.Add(nav);
        }

        var divider = new Panel { Location = new Point(12, navTop + titles.Length * 40 + 4), Size = new Size(166, 1),
            BackColor = Color.FromArgb(31, 31, 35) };
        host.Controls.Add(divider);
        BuildOllamaControls(host, navTop + titles.Length * 40 + 18);

        sidebarProxyStatus = new Label { Text = "○ Proxy idle", Location = new Point(16, host.Height - 58), Size = new Size(158, 17),
            Anchor = AnchorStyles.Left | AnchorStyles.Bottom, ForeColor = TextFaint, Font = new Font("Segoe UI", 8f) };
        sidebarCounts = new Label { Text = "0 skills · 0 terminals", Location = new Point(16, host.Height - 38), Size = new Size(158, 17),
            Anchor = AnchorStyles.Left | AnchorStyles.Bottom, ForeColor = TextFaint, Font = new Font("Segoe UI", 8f) };
        host.Controls.Add(sidebarProxyStatus);
        host.Controls.Add(sidebarCounts);
    }

    void BuildUi()
    {
        Text = "Hydra";
        FormBorderStyle = FormBorderStyle.None;   // custom chrome (title bar drawn below)
        Icon = AppIcon();
        // Match the Mac shell's roomy 940×640 baseline while still clamping to small displays.
        var wa = Screen.PrimaryScreen.WorkingArea;
        int startW = Math.Min(1040, wa.Width - 40);
        int startH = Math.Min(720, wa.Height - 40);
        MinimumSize = new Size(Math.Min(940, startW), Math.Min(640, startH));
        ClientSize = new Size(startW, startH);
        StartPosition = FormStartPosition.CenterScreen;
        BackColor = Bg;
        ForeColor = Color.White;
        Font = new Font("Segoe UI", 10f);
        DoubleBuffered = true;

        const int TOP = 34;         // custom title-bar height
        const int SIDEBAR = 190;

        BuildTitleBar(TOP);

        // Persistent Mac-style sidebar: brand, vertical navigation, Ollama, and status footer.
        sidebar = new Panel { Location = new Point(0, TOP), Size = new Size(SIDEBAR, ClientSize.Height - TOP),
            Anchor = AnchorStyles.Top | AnchorStyles.Bottom | AnchorStyles.Left, BackColor = TitleBg };
        BuildSidebar(sidebar);
        Controls.Add(sidebar);
        var sideDivider = new Panel { Location = new Point(SIDEBAR - 1, TOP), Size = new Size(1, ClientSize.Height - TOP),
            Anchor = AnchorStyles.Top | AnchorStyles.Bottom | AnchorStyles.Left, BackColor = Color.FromArgb(35, 35, 39) };
        Controls.Add(sideDivider);

        // Main content uses the same flat charcoal canvas as the Mac app.
        var content = new Panel { Location = new Point(SIDEBAR, TOP),
            Size = new Size(ClientSize.Width - SIDEBAR, ClientSize.Height - TOP),
            Anchor = AnchorStyles.Top | AnchorStyles.Bottom | AnchorStyles.Left | AnchorStyles.Right,
            BackColor = Bg };
        Controls.Add(content);

        var pWork     = NewContentPanel(content);
        var pSettings = NewContentPanel(content);
        var pSaas     = NewContentPanel(content);
        var pSkills   = NewContentPanel(content);
        var pGloss    = NewContentPanel(content);

        BuildWorkspaceTab(pWork);
        BuildSettingsTab(pSettings);
        BuildSaasTab(pSaas);
        BuildSkillsTab(pSkills);
        BuildGlossaryTab(pGloss);

        Modernize(content);
        SelectNav(0);
    }

    Panel NewContentPanel(Control host)
    {
        var p = new Panel { Dock = DockStyle.Fill, BackColor = Bg, Visible = false, Padding = new Padding(0) };
        host.Controls.Add(p);
        contentPanels.Add(p);
        return p;
    }

    void SelectNav(int sel)
    {
        for (int i = 0; i < navButtons.Count; i++)
        {
            var b = navButtons[i];
            bool on = i == sel;
            b.Tag = on;
            b.BackColor = on ? Lerp(TitleBg, Accent, 0.16f) : TitleBg;
            b.ForeColor = on ? Color.White : TextDim;
            b.Font = new Font("Segoe UI", 9.5f, on ? FontStyle.Bold : FontStyle.Regular);
            b.Invalidate();
        }
        for (int i = 0; i < contentPanels.Count; i++)
            contentPanels[i].Visible = i == sel;
    }

    // walk the content tree and modernize input controls to the flat field look
    void Modernize(Control root)
    {
        foreach (Control c in root.Controls)
        {
            if (c is TextBox)
            {
                var t = (TextBox)c;
                if (t.BackColor == Panel2) { t.BorderStyle = BorderStyle.FixedSingle; t.BackColor = Field; }
            }
            else if (c is ComboBox)
            {
                var cb = (ComboBox)c;
                StyleDarkCombo(cb);
            }
            else if (c is ListBox)
            {
                var lb = (ListBox)c;
                lb.BorderStyle = BorderStyle.None; lb.BackColor = Field;
            }
            else if (c is ListView)
            {
                var lv = (ListView)c;
                lv.BorderStyle = BorderStyle.None; if (lv.BackColor == Panel2) lv.BackColor = Field;
            }
            if (c.HasChildren) Modernize(c);
        }
    }

    void StyleDarkCombo(ComboBox cb)
    {
        cb.FlatStyle = FlatStyle.Flat;
        cb.BackColor = Field;
        cb.ForeColor = Color.White;
        if (cb.DrawMode == DrawMode.OwnerDrawFixed) return;
        cb.DrawMode = DrawMode.OwnerDrawFixed;
        cb.ItemHeight = 22;
        cb.DrawItem += (s, e) => {
            Color fill = (e.State & DrawItemState.Selected) != 0 ? FieldHi : Field;
            using (var brush = new SolidBrush(fill)) e.Graphics.FillRectangle(brush, e.Bounds);
            string text = e.Index >= 0 && e.Index < cb.Items.Count ? cb.Items[e.Index].ToString() : cb.Text;
            TextRenderer.DrawText(e.Graphics, text ?? "", cb.Font,
                new Rectangle(e.Bounds.X + 6, e.Bounds.Y, Math.Max(0, e.Bounds.Width - 8), e.Bounds.Height),
                Color.White, TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);
            if ((e.State & DrawItemState.Focus) != 0) e.DrawFocusRectangle();
        };
    }

    Label Caption(string t, int x, int y) { return new Label { Text = t, AutoSize = true, Location = new Point(x, y), ForeColor = TextDim }; }

    // A row-height caption for the responsive TableLayoutPanel rows.
    Label RowCap(string t) { return new Label { Text = t, Dock = DockStyle.Fill, ForeColor = TextDim,
        TextAlign = ContentAlignment.MiddleLeft, UseMnemonic = false, Margin = new Padding(0), Font = new Font("Segoe UI", 8.5f) }; }

    // Unified workspace: launch controls live on the left, the live embedded terminals
    // fill the right — so configuring, launching, and using Claude all happen in one view.
    void BuildTitleBar(int h)
    {
        titleBar = new Panel { Dock = DockStyle.Top, Height = h, BackColor = TitleBg };
        Controls.Add(titleBar);
        titleBar.MouseDown += (s, e) => { if (e.Button == MouseButtons.Left) DragTitleBar(); };
        titleBar.MouseDoubleClick += (s, e) => { if (e.Button == MouseButtons.Left) ToggleMaxRestore(); };

        btnMin   = CaptionButton("–", h, false);   // en dash
        btnMax   = CaptionButton("□", h, false);   // square
        btnClose = CaptionButton("✕", h, true);    // multiplication x
        btnMin.Click   += (s, e) => WindowState = FormWindowState.Minimized;
        btnMax.Click   += (s, e) => ToggleMaxRestore();
        btnClose.Click += (s, e) => Close();
        titleBar.Controls.Add(btnMin);
        titleBar.Controls.Add(btnMax);
        titleBar.Controls.Add(btnClose);
        LayoutCaptionButtons();
        titleBar.Resize += (s, e) => LayoutCaptionButtons();
    }

    Button CaptionButton(string glyph, int h, bool danger)
    {
        var b = new Button { Text = glyph, Size = new Size(46, h), FlatStyle = FlatStyle.Flat,
            BackColor = TitleBg, ForeColor = TextDim, TabStop = false, Cursor = Cursors.Hand,
            Font = new Font("Segoe UI", 10.5f), Anchor = AnchorStyles.Top | AnchorStyles.Right };
        b.FlatAppearance.BorderSize = 0;
        b.FlatAppearance.MouseOverBackColor = danger ? Color.FromArgb(205, 65, 60) : FieldHi;
        b.FlatAppearance.MouseDownBackColor = danger ? Color.FromArgb(175, 50, 45) : Field;
        b.MouseEnter += (s, e) => b.ForeColor = Color.White;
        b.MouseLeave += (s, e) => b.ForeColor = TextDim;
        return b;
    }

    void LayoutCaptionButtons()
    {
        if (btnClose == null) return;
        int w = titleBar.ClientSize.Width, bw = 46;
        btnClose.Location = new Point(w - bw, 0);
        btnMax.Location   = new Point(w - bw * 2, 0);
        btnMin.Location   = new Point(w - bw * 3, 0);
    }

    // Minimal workspace: the embedded terminals fill the ENTIRE tab. The only launch
    // control is a compact "Recent folders" dropdown in the terminals toolbar, so almost
    // all the space goes to the live sessions.
    void BuildWorkspaceTab(Control tab)
    {
        BuildTerminalsTab(tab);
    }

    Label SectionCap(string t)
    {
        return new Label { Text = t, Dock = DockStyle.Fill, ForeColor = Color.White,
            Font = new Font("Segoe UI Semibold", 10.5f, FontStyle.Bold), Margin = new Padding(0, 6, 0, 0) };
    }

    Control PageHeader(string title, string subtitle)
    {
        var panel = new Panel { Dock = DockStyle.Fill, BackColor = Color.Transparent, Margin = new Padding(0) };
        panel.Controls.Add(new Label { Text = title, Location = new Point(0, 1), Size = new Size(700, 25),
            Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right,
            ForeColor = Color.White, Font = new Font("Segoe UI Semibold", 14f, FontStyle.Bold) });
        panel.Controls.Add(new Label { Text = subtitle, Location = new Point(0, 28), Size = new Size(700, 20),
            Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right,
            ForeColor = TextDim, Font = new Font("Segoe UI", 8.5f) });
        return panel;
    }

    // Dedicated Settings tab: everything that used to crowd the launch column now lives
    // here — launch defaults, the three token-compression toggles, extra flags, and a few
    // maintenance actions — leaving the Workspace tab minimal and clean.
    void BuildSettingsTab(Control tab)
    {
        var root = new TableLayoutPanel {
            Dock = DockStyle.Fill, BackColor = Color.Transparent, ColumnCount = 1,
            AutoScroll = true, Padding = new Padding(22, 16, 22, 18) };
        root.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100f));
        tab.Controls.Add(root);

        Action<Control, int> row = (c, h) => {
            c.Margin = new Padding(0, 2, 0, 2);
            if (h > 0) { c.Dock = DockStyle.Fill; root.RowStyles.Add(new RowStyle(SizeType.Absolute, h)); }
            root.Controls.Add(c);
        };

        row(PageHeader("Settings", "Defaults for every new terminal, the token-compression toolchain, and one-click install."), 52);

        // ---- launch defaults ----
        row(SectionCap("Launch defaults"), 26);
        var mp = new TableLayoutPanel { ColumnCount = 3, RowCount = 2, Dock = DockStyle.Fill, BackColor = Color.Transparent, Margin = new Padding(0) };
        mp.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 130f));
        mp.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50f));
        mp.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50f));
        mp.RowStyles.Add(new RowStyle(SizeType.Absolute, 20f));
        mp.RowStyles.Add(new RowStyle(SizeType.Absolute, 30f));
        var acap = RowCap("Agent"); acap.Margin = new Padding(0, 0, 6, 0);
        var mcap = RowCap("Claude / ChatGPT model"); mcap.Margin = new Padding(0, 0, 6, 0);
        var pcap = RowCap("Permissions (Codex: YOLO)"); pcap.Margin = new Padding(6, 0, 0, 0);
        agentCombo = new ComboBox { Dock = DockStyle.Fill, DropDownStyle = ComboBoxStyle.DropDownList, FlatStyle = FlatStyle.Flat, BackColor = Panel2, ForeColor = Color.White, Margin = new Padding(0, 1, 6, 1) };
        agentCombo.Items.AddRange(new object[] { "Claude", "Codex" });
        agentCombo.SelectedIndex = 0;
        agentCombo.SelectedIndexChanged += (s, e) => {
            if (!loadingSettings) RememberVisibleModelForAgent(activeModelAgent);
            RefreshModelChoicesForAgent();
            if (termAgentCombo != null && termAgentCombo.SelectedItem != agentCombo.SelectedItem) termAgentCombo.SelectedItem = agentCombo.SelectedItem;
            UpdateLaunchText(); if (!loadingSettings) SaveSettings();
        };
        modelCombo = new ComboBox { Dock = DockStyle.Fill, DropDownStyle = ComboBoxStyle.DropDownList, FlatStyle = FlatStyle.Flat, BackColor = Panel2, ForeColor = Color.White, Margin = new Padding(0, 1, 6, 1) };
        modelCombo.Items.AddRange(ClaudeModelChoices);
        modelCombo.Text = "Default";
        modelCombo.TextChanged += (s, e) => {
            if (!refreshingModelChoices) RememberVisibleModelForAgent(ActiveLaunchAgent());
            UpdateLaunchText();
            if (!loadingSettings && !refreshingModelChoices) SaveSettings();
        };
        permCombo = new ComboBox { Dock = DockStyle.Fill, DropDownStyle = ComboBoxStyle.DropDownList, FlatStyle = FlatStyle.Flat, BackColor = Panel2, ForeColor = Color.White, Margin = new Padding(6, 1, 0, 1) };
        permCombo.Items.AddRange(new object[] { "Bypass – skip all prompts", "Plan mode (read-only)", "Accept edits automatically", "Ask for each action" });
        permCombo.SelectedIndex = 0;
        mp.Controls.Add(acap, 0, 0); mp.Controls.Add(mcap, 1, 0); mp.Controls.Add(pcap, 2, 0);
        mp.Controls.Add(agentCombo, 0, 1); mp.Controls.Add(modelCombo, 1, 1); mp.Controls.Add(permCombo, 2, 1);
        row(mp, 52);

        continueChk = new CheckBox { Text = "Continue last conversation (--continue)", AutoSize = false };
        row(continueChk, 26);

        // ---- token compression ----
        row(SectionCap("Token compression"), 26);
        row(RowCap("Each toggle is independent — mix & match freely:"), 22);
        hrCheck = new CheckBox { Text = "Headroom — proxy compresses all tool output & context (per launch)",
            AutoSize = false, Checked = false, UseMnemonic = false, TextAlign = ContentAlignment.MiddleLeft };
        hrCheck.CheckedChanged += (s, e) => { UpdateLaunchText(); UpdateCompressionAdvisory(); };
        row(hrCheck, 26);
        hrStatus = new Label { AutoSize = false, UseMnemonic = false, TextAlign = ContentAlignment.MiddleLeft,
            Margin = new Padding(20, 0, 0, 0), Font = new Font("Segoe UI", 8.5f) };
        row(hrStatus, 20);

        rtCheck = new CheckBox { Text = "RTK — filter shell/test/build command output (Claude hook + Codex instructions)",
            AutoSize = false, UseMnemonic = false, TextAlign = ContentAlignment.MiddleLeft };
        rtCheck.CheckedChanged += (s, e) => { if (!suppressRtk) SetRtk(rtCheck.Checked); else UpdateLaunchText(); };
        row(rtCheck, 26);
        rtStatus = new Label { AutoSize = false, UseMnemonic = false, TextAlign = ContentAlignment.MiddleLeft,
            Margin = new Padding(20, 0, 0, 0), Font = new Font("Segoe UI", 8.5f) };
        row(rtStatus, 20);

        cvCheck = new CheckBox { Text = "Caveman — compress agent replies (Claude plugin + Codex instructions)",
            AutoSize = false, UseMnemonic = false, TextAlign = ContentAlignment.MiddleLeft };
        cvCheck.CheckedChanged += (s, e) => { if (!suppressCaveman) SetCaveman(cvCheck.Checked); else UpdateLaunchText(); };
        row(cvCheck, 26);
        cvStatus = new Label { AutoSize = false, UseMnemonic = false, TextAlign = ContentAlignment.MiddleLeft,
            Margin = new Padding(20, 0, 0, 0), Font = new Font("Segoe UI", 8.5f) };
        row(cvStatus, 20);

        compAdvisory = new Label { AutoSize = false, UseMnemonic = false, TextAlign = ContentAlignment.MiddleLeft,
            ForeColor = TextDim, Font = new Font("Segoe UI", 8.5f) };
        row(compAdvisory, 26);

        // ---- extra flags ----
        row(SectionCap("Extra flags"), 26);
        row(RowCap("Appended verbatim to every launch (optional)"), 18);
        extraBox = new TextBox { Dock = DockStyle.Fill, BackColor = Panel2, ForeColor = Color.White, BorderStyle = BorderStyle.FixedSingle };
        row(extraBox, 28);

        // ---- install & setup (folded in from the old Setup tab; single home for everything) ----
        row(SectionCap("Install & setup"), 26);
        row(RowCap("Bootstrap a fresh machine, or install / repair individual pieces:"), 18);

        setupStatus = new Label { Dock = DockStyle.Fill, ForeColor = TextDim, Font = new Font("Consolas", 9f) };
        row(setupStatus, 20);

        var allBtn = new Button { Text = "Install everything  (Node + Claude/Codex CLI + RTK + Caveman + Video + Agent Skills + skills)", Dock = DockStyle.Fill,
            FlatStyle = FlatStyle.Flat, ForeColor = Color.Black, Font = new Font("Segoe UI", 10.5f, FontStyle.Bold) };
        Hoverize(allBtn, Accent, AccentHi);
        allBtn.Click += (s, e) => SetupRun(InstallEverything);
        setupAllBtn = allBtn;
        row(allBtn, 40);

        setupAllCap = RowCap("Fresh machine? \"Install everything\" auto-installs Node.js LTS first, then the latest Claude/Codex CLI + tools.");
        row(setupAllCap, 18);

        var updBtn = new Button { Text = "Update core packages  (npm · Claude CLI · Codex CLI · RTK · Caveman · Video · Agent Skills)", Dock = DockStyle.Fill,
            FlatStyle = FlatStyle.Flat, ForeColor = Color.White, Font = new Font("Segoe UI", 10f, FontStyle.Bold) };
        Hoverize(updBtn, Color.FromArgb(70, 110, 150), Color.FromArgb(86, 130, 172));
        updBtn.Click += (s, e) => SetupRun(UpdateCore);
        setupUpdBtn = updBtn;
        row(updBtn, 38);

        // one shared refresh that updates BOTH the setup status line and the toggle statuses,
        // so there is no separate "Refresh tool status" button (that duplication is gone).
        Action refreshAll = () => { DetectStatus(); UpdateProxyStatus(); UpdateRtkStatus(); UpdateCavemanStatus(); UpdateCompressionAdvisory(); };

        var tools = new FlowLayoutPanel { Dock = DockStyle.Fill, BackColor = Color.Transparent, Margin = new Padding(0, 2, 0, 2), WrapContents = true, AutoScroll = false };
        Action<string, Color, Color, EventHandler> mk = (text, n, hov, click) => {
            var b = new Button { Text = text, AutoSize = true, FlatStyle = FlatStyle.Flat, ForeColor = Color.White, Margin = new Padding(0, 2, 8, 2) };
            Hoverize(b, n, hov); b.Click += click; tools.Controls.Add(b);
        };
        mk("Claude CLI", Color.FromArgb(70, 120, 85), Color.FromArgb(84, 140, 100), (s, e) => SetupRun(InstallClaudeCli));
        mk("Codex CLI", Color.FromArgb(70, 120, 85), Color.FromArgb(84, 140, 100), (s, e) => SetupRun(InstallCodexCli));
        mk("Node.js", Panel2, FieldHi, (s, e) => SetupRun(() => { EnsureNode(); }));
        mk("RTK", Panel2, FieldHi, (s, e) => SetupRun(InstallRtk));
        mk("Caveman", Panel2, FieldHi, (s, e) => SetupRun(InstallCaveman));
        mk("Claude Video", Panel2, FieldHi, (s, e) => SetupRun(InstallClaudeVideoIfPossible));
        mk("Agent Skills", Panel2, FieldHi, (s, e) => SetupRun(InstallAgentSkillsIfPossible));
        mk("Headroom", Panel2, FieldHi, (s, e) => SetupRun(InstallHeadroom));
        mk("Skills", Panel2, FieldHi, (s, e) => InstallSkillsClicked());
        mk("Open .claude", Panel2, FieldHi, (s, e) => { try { string d = Path.Combine(HomeDir, ".claude"); Directory.CreateDirectory(d); Process.Start(d); } catch { } });
        mk("Refresh", Panel2, FieldHi, (s, e) => refreshAll());
        row(tools, 40);

        setupOut = new TextBox { Dock = DockStyle.Fill, Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Both, WordWrap = false,
            BackColor = Color.FromArgb(18, 18, 20), ForeColor = Color.FromArgb(210, 210, 215),
            BorderStyle = BorderStyle.FixedSingle, Font = new Font("Consolas", 9.5f),
            Text = "Ready. Click \"Install everything\" on a fresh machine, or install pieces individually." };
        row(setupOut, 190);

        DetectStatus();
    }

    void BuildSkillsTab(Control tab)
    {
        int W = 760;
        var header = PageHeader("Skills", "Manage skills for Claude and ChatGPT/Codex.");
        header.Location = new Point(22, 16); header.Size = new Size(W, 52);
        header.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right;
        tab.Controls.Add(header);
        skillsCount = new Label { AutoSize = true, Location = new Point(22, 70), ForeColor = TextDim };
        tab.Controls.Add(skillsCount);

        skillsList = new ListView { Location = new Point(22, 94), Size = new Size(W, 474),
            Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right | AnchorStyles.Bottom,
            View = View.Details, FullRowSelect = true, MultiSelect = false, HideSelection = false,
            BackColor = Panel2, ForeColor = Color.White, BorderStyle = BorderStyle.FixedSingle };
        skillsList.Columns.Add("Skill", 170);
        skillsList.Columns.Add("Status", 80);
        skillsList.Columns.Add("Description", 400);
        skillsList.DoubleClick += (s, e) => ToggleSkill();
        tab.Controls.Add(skillsList);

        int y = 576;
        var add = OkBtn("Import…");             add.Location = new Point(22, y);  add.Size = new Size(104, 32); add.Click += (s, e) => AddSkill();       tab.Controls.Add(add);
        var tog = GhostBtn("Enable / Disable"); tog.Location = new Point(134, y); tog.Size = new Size(130, 32); tog.Click += (s, e) => ToggleSkill();    tab.Controls.Add(tog);
        var rem = DangerBtn("Remove");          rem.Location = new Point(272, y); rem.Size = new Size(96, 32);  rem.Click += (s, e) => RemoveSkill();    tab.Controls.Add(rem);
        var refr = GhostBtn("Refresh");         refr.Location = new Point(376, y); refr.Size = new Size(90, 32); refr.Click += (s, e) => LoadSkills();   tab.Controls.Add(refr);
        var open = GhostBtn("Open folder");     open.Location = new Point(474, y); open.Size = new Size(110, 32); open.Click += (s, e) => OpenSkillsFolder(); tab.Controls.Add(open);

        foreach (Control c in tab.Controls) if (c is Button) c.Anchor = AnchorStyles.Bottom | AnchorStyles.Left;
    }

    void BuildGlossaryTab(Control tab)
    {
        int W = 760;
        var header = PageHeader("Glossary & reference", "Slash commands, CLI flags, keyboard tips, and the compression toolchain.");
        header.Location = new Point(22, 16); header.Size = new Size(W, 52);
        header.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right;
        tab.Controls.Add(header);
        glossarySearch = new TextBox { Location = new Point(22, 78), Size = new Size(W, 28),
            Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right, BackColor = Panel2, ForeColor = Color.White,
            BorderStyle = BorderStyle.FixedSingle, Font = new Font("Segoe UI", 11f) };
        glossarySearch.TextChanged += (s, e) => RenderGlossary(glossarySearch.Text);
        tab.Controls.Add(glossarySearch);

        glossaryList = new ListView { Location = new Point(22, 118), Size = new Size(W, 516),
            Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right | AnchorStyles.Bottom,
            View = View.Details, FullRowSelect = true, MultiSelect = false, HideSelection = false, ShowGroups = true,
            BackColor = Panel2, ForeColor = Color.White, BorderStyle = BorderStyle.FixedSingle };
        glossaryList.Columns.Add("Command / Key", 240);
        glossaryList.Columns.Add("What it does", 410);
        tab.Controls.Add(glossaryList);
    }

    // ================= Setup / bootstrap helpers (UI now lives in the Settings tab) =================
    static bool HasNpm() { return OnPath("npm.cmd") || OnPath("npm.exe") || OnPath("npm"); }
    static bool HasNpx() { return OnPath("npx.cmd") || OnPath("npx.exe") || OnPath("npx"); }
    static bool HasClaude() { return OnPath("claude.cmd") || OnPath("claude.exe") || OnPath("claude"); }
    static bool HasCodex() { return OnPath("codex.cmd") || OnPath("codex.exe") || OnPath("codex"); }
    static string RtkLocalPath() { return Path.Combine(HomeDir, ".local", "bin", "rtk.exe"); }
    static bool HasRtk() { return OnPath("rtk.exe") || OnPath("rtk") || File.Exists(RtkLocalPath()); }
    static bool HasNode() { return OnPath("node.exe") || OnPath("node"); }
    static bool HasWinget() { return OnPath("winget.exe") || OnPath("winget"); }

    // Re-read PATH from the registry (machine + user) into THIS process so that tools
    // installed during this session (Node, npm shims) resolve without restarting the app.
    void RefreshPathFromRegistry()
    {
        try
        {
            string m = (Microsoft.Win32.Registry.GetValue(@"HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Session Manager\Environment", "Path", "") as string) ?? "";
            string u = (Microsoft.Win32.Registry.GetValue(@"HKEY_CURRENT_USER\Environment", "Path", "") as string) ?? "";
            string combined = m;
            if (u.Length > 0) combined = combined.TrimEnd(';') + ";" + u;
            // belt-and-suspenders: add the well-known install dirs in case the registry hasn't propagated yet
            string[] extra = {
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "nodejs"),
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "npm"),
                Path.Combine(HomeDir, ".local", "bin")
            };
            foreach (var d in extra)
                if (Directory.Exists(d) && combined.IndexOf(d, StringComparison.OrdinalIgnoreCase) < 0)
                    combined = combined.TrimEnd(';') + ";" + d;
            Environment.SetEnvironmentVariable("PATH", combined, EnvironmentVariableTarget.Process);
        }
        catch (Exception ex) { SetupLog("  (PATH refresh warning: " + ex.Message + ")"); }
    }

    // Guarantee Node.js + npm exist. Tries winget first, then a silent LTS MSI download.
    // Returns true if npm is usable afterwards. Safe to call repeatedly.
    bool EnsureNode()
    {
        RefreshPathFromRegistry();
        if (HasNpm()) return true;
        SetupLog("Node.js/npm not found — installing the latest Node LTS…");
        if (HasWinget())
        {
            SetupLog("> winget install OpenJS.NodeJS.LTS");
            RunLoggedCmd("winget install --id OpenJS.NodeJS.LTS -e --source winget --silent --accept-source-agreements --accept-package-agreements");
            RefreshPathFromRegistry();
            if (HasNpm()) { SetupLog("OK  Node.js installed via winget."); return true; }
        }
        SetupLog("Falling back to the official Node LTS installer (silent MSI)…");
        RunPowerShellScript(NodeMsiScript());
        RefreshPathFromRegistry();
        if (HasNpm()) { SetupLog("OK  Node.js + npm installed."); return true; }
        SetupLog("Could not install Node automatically. Install LTS from https://nodejs.org/en/download and retry.");
        try { Process.Start("https://nodejs.org/en/download"); } catch { }
        return false;
    }

    static string NodeMsiScript()
    {
        return @"$ErrorActionPreference='Stop'
try {
  $idx = Invoke-RestMethod 'https://nodejs.org/dist/index.json'
  $lts = $idx | Where-Object { $_.lts } | Select-Object -First 1
  $ver = $lts.version
  $arch = if ([Environment]::Is64BitOperatingSystem) { 'x64' } else { 'x86' }
  $url = ""https://nodejs.org/dist/$ver/node-$ver-$arch.msi""
  $msi = Join-Path $env:TEMP ""node-$ver-$arch.msi""
  Write-Host ('Downloading ' + $url)
  Invoke-WebRequest $url -OutFile $msi -UseBasicParsing
  Write-Host 'Installing Node.js silently (may take a minute)…'
  $p = Start-Process msiexec.exe -ArgumentList '/i',(""`""$msi`""""),'/qn','/norestart' -Wait -PassThru
  Write-Host ('msiexec exit ' + $p.ExitCode)
  Remove-Item $msi -Force -ErrorAction SilentlyContinue
} catch { Write-Host ('ERR Node install failed: ' + $_.Exception.Message) }";
    }

    int CountSkills()
    {
        int n = 0;
        try { if (Directory.Exists(SkillsDir)) foreach (var d in Directory.GetDirectories(SkillsDir)) if (File.Exists(Path.Combine(d, "SKILL.md"))) n++; }
        catch { }
        return n;
    }

    static bool VideoInstalled()
    {
        try
        {
            if (File.Exists(Path.Combine(SkillsDir, "watch", "SKILL.md"))) return true;
            if (File.Exists(Path.Combine(CodexSkillsDir, "watch", "SKILL.md"))) return true;
            if (File.Exists(PluginsFile) && File.ReadAllText(PluginsFile).IndexOf("watch@claude-video", StringComparison.OrdinalIgnoreCase) >= 0) return true;
            if (File.Exists(Path.Combine(HomeDir, ".claude", "plugins", "marketplaces", "claude-video", ".claude-plugin", "plugin.json"))) return true;
        }
        catch { }
        return false;
    }

    static bool AgentSkillsInstalled()
    {
        return File.Exists(Path.Combine(SkillsDir, "using-agent-skills", "SKILL.md"))
            && File.Exists(Path.Combine(CodexSkillsDir, "using-agent-skills", "SKILL.md"));
    }

    static string Mark(bool ok) { return ok ? "OK" : "--"; }

    // Core toolchain fully present? (Headroom is optional.) When true, "Install everything"
    // is pointless, so we hide it and let the Setup tab focus on the Update button.
    bool AllCoreInstalled()
    {
        return HasClaude() && HasCodex() && (OnPath("node.exe") || OnPath("node")) && RtkInstalled() && CavemanInstalled() && VideoInstalled() && AgentSkillsInstalled();
    }

    void DetectStatus()
    {
        if (setupStatus == null) return;
        bool node = OnPath("node.exe") || OnPath("node");
        setupStatus.Text = "Claude " + Mark(HasClaude()) + "   Codex " + Mark(HasCodex()) + "   Node " + Mark(node) + "   RTK " + Mark(HasRtk() && RtkInstalled())
            + "   Caveman " + Mark(CavemanInstalled()) + "   Video " + Mark(VideoInstalled()) + "   AgentSkills " + Mark(AgentSkillsInstalled()) + "   Headroom " + Mark(OnPath("headroom.exe") || OnPath("headroom"))
            + "   Skills " + CountSkills();

        // Focus the tab: once everything's installed, drop "Install everything" and promote Update.
        bool all = AllCoreInstalled();
        if (setupAllBtn != null) setupAllBtn.Visible = !all;
        if (setupAllCap != null)
            setupAllCap.Text = all
                ? "Your toolchain is complete — just keep it fresh with \"Update core packages\" below."
                : "Fresh machine? \"Install everything\" auto-installs Node.js LTS first, then the latest Claude/Codex CLI + tools.";
        if (setupUpdBtn != null)
        {
            setupUpdBtn.Text = all ? "Update core packages  (npm · Claude CLI · Codex CLI · RTK · Caveman · Video · Agent Skills)   ✓ everything installed"
                                   : "Update core packages  (npm · Claude CLI · Codex CLI · RTK · Caveman · Video · Agent Skills)";
            // promote Update to the primary (accent) style when it's the main action
            Hoverize(setupUpdBtn, all ? Accent : Color.FromArgb(70, 110, 150),
                                  all ? AccentHi : Color.FromArgb(86, 130, 172));
            setupUpdBtn.ForeColor = all ? Color.Black : Color.White;
        }
    }

    void SetupLog(string line)
    {
        try
        {
            if (setupOut == null) return;
            if (setupOut.InvokeRequired) { setupOut.BeginInvoke((Action)(() => SetupLog(line))); return; }
            setupOut.AppendText("\r\n" + line);
        }
        catch { }
    }

    // run a command through cmd /c so PATH + .cmd shims resolve; stream output to the log. Call from a bg thread.
    int RunLoggedCmd(string commandLine)
    {
        SetupLog("> " + commandLine);
        try
        {
            var psi = new ProcessStartInfo("cmd.exe", "/c " + commandLine)
            { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
            var p = Process.Start(psi);
            p.OutputDataReceived += (s, e) => { if (e.Data != null) SetupLog(e.Data); };
            p.ErrorDataReceived += (s, e) => { if (e.Data != null) SetupLog(e.Data); };
            p.BeginOutputReadLine(); p.BeginErrorReadLine();
            p.WaitForExit();
            return p.ExitCode;
        }
        catch (Exception ex) { SetupLog("  ERR " + ex.Message); return -1; }
    }

    void RunPowerShellScript(string script)
    {
        string tmp = Path.Combine(Path.GetTempPath(), "cm_" + Guid.NewGuid().ToString("N") + ".ps1");
        try { File.WriteAllText(tmp, script); RunLoggedCmd("powershell -NoProfile -ExecutionPolicy Bypass -File \"" + tmp + "\""); }
        catch (Exception ex) { SetupLog("  ERR " + ex.Message); }
        finally { try { File.Delete(tmp); } catch { } }
    }

    void SetupRun(Action work)
    {
        if (setupBusy) { SetupLog("(busy — wait for the current step to finish)"); return; }
        setupBusy = true;
        var th = new Thread(() =>
        {
            try { work(); }
            catch (Exception ex) { SetupLog("ERR " + ex.Message); }
            finally { setupBusy = false; try { BeginInvoke((Action)DetectStatus); } catch { } }
        });
        th.IsBackground = true; th.Start();
    }

    void InstallClaudeCli()
    {
        EnsureNode();   // helpful for Caveman, but the native Claude installer doesn't need it
        SetupLog("Installing latest Claude CLI (native installer, npm fallback)…");
        int rc = RunLoggedCmd(ClaudeInstallCmd());
        SetupLog(rc == 0 ? "OK  Claude CLI installed (latest)." : "Claude CLI install returned exit " + rc + ".");
    }

    void InstallCodexCli()
    {
        if (!EnsureNode()) return;
        SetupLog("Installing latest Codex CLI (npm)…");
        int rc = RunLoggedCmd(CodexInstallCmd());
        SetupLog(rc == 0 ? "OK  Codex CLI installed (latest)." : "Codex CLI install returned exit " + rc + ".");
        if (HasRtk()) RunLoggedCmd("rtk init -g --codex");
        EnsureCodexCavemanInstructions();
        InstallBundledCavemanForCodexIfPossible();
        InstallClaudeVideoIfPossible();
        InstallAgentSkillsIfPossible();
    }


    void InstallRtk()
    {
        if (!(OnPath("rtk.exe") || OnPath("rtk") || File.Exists(RtkLocalPath())))
        {
            SetupLog("Downloading RTK (Windows binary) to ~/.local/bin …");
            RunPowerShellScript(RtkDownloadScript());
        }
        else SetupLog("rtk binary already present.");
        string rtk = File.Exists(RtkLocalPath()) ? "\"" + RtkLocalPath() + "\"" : "rtk";
        SetupLog("Registering RTK hook (rtk init -g --auto-patch)…");
        int rc = RunLoggedCmd(rtk + " init -g --auto-patch");
        RunLoggedCmd(rtk + " init -g --codex");
        SetupLog(rc == 0 ? "OK  RTK hook registered (default input compression)." : "RTK init returned exit " + rc + ".");
        try { BeginInvoke((Action)UpdateRtkStatus); } catch { }
    }

    static string RtkDownloadScript()
    {
        return @"$ErrorActionPreference='Stop'
try {
  $bin = Join-Path $env:USERPROFILE '.local\bin'
  New-Item -ItemType Directory -Force -Path $bin | Out-Null
  $r = Invoke-RestMethod 'https://api.github.com/repos/rtk-ai/rtk/releases/latest' -Headers @{'User-Agent'='rtk-installer'}
  $a = ($r.assets | Where-Object { $_.name -like '*windows-msvc.zip' } | Select-Object -First 1).browser_download_url
  $tmp = Join-Path $env:TEMP ('rtk_' + [guid]::NewGuid())
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  $z = Join-Path $tmp 'rtk.zip'
  Invoke-WebRequest $a -OutFile $z
  Expand-Archive $z -DestinationPath $tmp -Force
  $exe = Get-ChildItem $tmp -Recurse -Filter rtk.exe | Select-Object -First 1
  Copy-Item $exe.FullName (Join-Path $bin 'rtk.exe') -Force
  Remove-Item $tmp -Recurse -Force
  Write-Host 'OK  RTK downloaded to ~/.local/bin/rtk.exe'
} catch { Write-Host ('ERR RTK download failed: ' + $_.Exception.Message) }";
    }

    void InstallCaveman()
    {
        if (CavemanInstalled()) { SetupLog("Caveman already installed."); return; }
        if (!EnsureNode()) return;
        SetupLog("Installing Caveman plugin/instructions for Claude Code + Codex CLI…");
        int rc = RunLoggedCmd("npx -y github:JuliusBrussee/caveman --only claude --only codex");
        EnsureCodexCavemanInstructions();
        InstallBundledCavemanForCodexIfPossible();
        InstallClaudeVideoIfPossible();
        InstallAgentSkillsIfPossible();
        SetupLog(rc == 0 ? "OK  Caveman installed (default output compression)." : "Caveman install returned exit " + rc + ".");
        try { BeginInvoke((Action)(() => { UpdateCavemanStatus(); UpdateLaunchText(); })); } catch { }
    }

    void InstallHeadroom()
    {
        if (OnPath("headroom.exe") || OnPath("headroom")) { SetupLog("Headroom already installed (optional)."); return; }
        SetupLog("Installing Headroom (optional input tool)…");
        string[,] tries = { { "pipx", "pipx install \"headroom-ai[all]\"" }, { "uv", "uv tool install \"headroom-ai[all]\"" },
                            { "pip", "pip install \"headroom-ai[all]\"" }, { "python", "python -m pip install \"headroom-ai[all]\"" } };
        bool ok = false;
        for (int i = 0; i < tries.GetLength(0); i++)
        {
            string tool = tries[i, 0];
            if (OnPath(tool) || OnPath(tool + ".exe") || OnPath(tool + ".cmd"))
            {
                if (RunLoggedCmd(tries[i, 1]) == 0) { ok = true; break; }
            }
        }
        SetupLog(ok ? "OK  Headroom installed. It's OPTIONAL — enable it per-launch on the Launch tab."
                    : "Could not install Headroom. Install Python 3.10+ (or pipx/uv), then retry.");
    }

    // ---- native toolchain: ship binaries so the user downloads nothing ----
    // Finds the bundled `tools/` payload (next to the exe or in the repo).
    string FindToolsSource()
    {
        try
        {
            string exeDir = Path.GetDirectoryName(Application.ExecutablePath);
            string parent = Path.GetDirectoryName(exeDir) ?? exeDir;
            string[] cands = {
                Path.Combine(exeDir, "tools"),
                Path.Combine(parent, "tools"),
                Path.Combine(HomeDir, "Desktop", "HYDRA", "tools")
            };
            foreach (var c in cands)
                if (Directory.Exists(c) && File.Exists(Path.Combine(c, "manifest.json"))) return c;
        }
        catch { }
        return null;
    }

    // Provision claude/rtk/caveman natively. Idempotent; slow parts run on a background thread.
    void ProvisionNativeToolchain()
    {
        var th = new Thread(() =>
        {
            try
            {
                Directory.CreateDirectory(ManagedBin);
                string src = FindToolsSource();

                // 1) RTK — copy the bundled Windows binary into the managed bin (no download).
                string rtkDst = Path.Combine(ManagedBin, "rtk.exe");
                if (src != null)
                {
                    string bundledRtk = Path.Combine(src, "win-x64", "rtk.exe");
                    if (File.Exists(bundledRtk) && (!File.Exists(rtkDst) ||
                        new FileInfo(bundledRtk).Length != new FileInfo(rtkDst).Length))
                    {
                        try { File.Copy(bundledRtk, rtkDst, true); SetupLog("Native RTK ready (bundled, no download)."); } catch { }
                    }
                }
                if (!File.Exists(rtkDst) && !OnPath("rtk.exe") && !OnPath("rtk"))
                    { try { RunPowerShellScript(RtkDownloadScript()); } catch { } }
                // Register the RTK input-compression hook using whichever rtk is available.
                if (!RtkInstalled())
                {
                    string rtk = File.Exists(rtkDst) ? "\"" + rtkDst + "\"" : "rtk";
                    try { RunLoggedCmd(rtk + " init -g --auto-patch"); } catch { }
                }
                if (File.Exists(rtkDst) || OnPath("rtk.exe") || OnPath("rtk"))
                {
                    string rtk = File.Exists(rtkDst) ? "\"" + rtkDst + "\"" : "rtk";
                    try { RunLoggedCmd(rtk + " init -g --codex"); } catch { }
                }

                // 2) Caveman — seed the marketplace locally so the plugin installs OFFLINE from
                //    the bundled copy (no `npx github:…` fetch).
                if (src != null)
                {
                    string bundledCaveman = Path.Combine(src, "caveman");
                    string mkDst = Path.Combine(HomeDir, ".claude", "plugins", "marketplaces", "caveman");
                    if (Directory.Exists(bundledCaveman) && !Directory.Exists(mkDst))
                    {
                        try { CopyDir(bundledCaveman, mkDst); SetupLog("Native Caveman marketplace seeded (offline)."); } catch { }
                    }
                    if (!CavemanInstalled() && HasNode())
                    {
                        string installer = Path.Combine(Directory.Exists(mkDst) ? mkDst : bundledCaveman, "bin", "install.js");
                        if (File.Exists(installer))
                            try { RunLoggedCmd("node \"" + installer + "\" --only claude --only codex"); } catch { }
                    }
                    EnsureCodexCavemanInstructions();
                    InstallBundledCavemanForCodexIfPossible();
                }

                // 3) Claude CLI — not redistributable; install once, silently, if missing.
                //    Native installer needs no npm, so don't gate on it.
                if (!OnPath("claude.exe") && !OnPath("claude"))
                {
                    SetupLog("Claude CLI not found — installing it once…");
                    try { RunLoggedCmd(ClaudeInstallCmd()); } catch { }
                }

                if (!HasCodex() && HasNpm())
                {
                    SetupLog("Codex CLI not found — installing it once…");
                    try { RunLoggedCmd(CodexInstallCmd()); } catch { }
                }
                InstallClaudeVideoIfPossible();
                InstallAgentSkillsIfPossible();
            }
            catch { }
            try { BeginInvoke((Action)DetectStatus); } catch { }
        });
        th.IsBackground = true; th.Start();
    }

    string FindSkillsSource()
    {
        try
        {
            string exeDir = Path.GetDirectoryName(Application.ExecutablePath);
            string parent = Path.GetDirectoryName(exeDir) ?? exeDir;
            string[] cands = {
                Path.Combine(exeDir, "SKILLS-BACKUP"),
                Path.Combine(parent, "SKILLS-BACKUP"),
                Path.Combine(exeDir, "skills"),
                Path.Combine(exeDir, "ESSENTIAL-SKILLS"),
                Path.Combine(parent, "ESSENTIAL-SKILLS"),
                exeDir
            };
            foreach (var c in cands)
            {
                try { if (Directory.Exists(c) && Directory.GetFiles(c, "SKILL.md", SearchOption.AllDirectories).Length > 0) return c; }
                catch { }
            }
        }
        catch { }
        return null;
    }

    void InstallSkillsClicked()
    {
        string src = FindSkillsSource();
        if (src == null)
        {
            using (var dlg = new FolderBrowserDialog { Description = "Pick a folder containing skills (any SKILL.md inside)", ShowNewFolderButton = false })
            {
                if (dlg.ShowDialog() != DialogResult.OK) return;
                src = dlg.SelectedPath;
            }
        }
        SetupRun(() => DoInstallSkills(src));
    }

    void DoInstallSkills(string src)
    {
        string[] found;
        try { found = Directory.GetFiles(src, "SKILL.md", SearchOption.AllDirectories); }
        catch (Exception ex) { SetupLog("Skill scan failed: " + ex.Message); return; }
        if (found.Length == 0) { SetupLog("No SKILL.md found under " + src); return; }
        Directory.CreateDirectory(SkillsDir);
        Directory.CreateDirectory(CodexSkillsDir);
        int n = 0;
        foreach (var md in found)
        {
            string nm, ds; ReadMeta(md, out nm, out ds);
            string parent = Path.GetDirectoryName(md);
            if (string.IsNullOrEmpty(nm)) nm = new DirectoryInfo(parent).Name;
            bool copied = false;
            try { CopyDir(parent, Path.Combine(SkillsDir, nm)); copied = true; } catch (Exception ex) { SetupLog("  x Claude " + nm + ": " + ex.Message); }
            try { CopyDir(parent, Path.Combine(CodexSkillsDir, nm)); copied = true; } catch (Exception ex) { SetupLog("  x Codex " + nm + ": " + ex.Message); }
            if (copied) { n++; SetupLog("  + " + nm); }
        }
        SetupLog("OK  Installed/updated " + n + " skill(s) into " + SkillsDir + " and " + CodexSkillsDir);
        try { BeginInvoke((Action)LoadSkills); } catch { }
    }

    void InstallClaudeVideoIfPossible()
    {
        string src = FindToolsSource();
        if (src == null) { SetupLog("Claude Video skipped: bundled tools folder not found."); return; }
        string root = Path.Combine(src, "claude-video");
        string skill = Path.Combine(root, "skills", "watch");
        if (!File.Exists(Path.Combine(skill, "SKILL.md")))
        {
            SetupLog("Claude Video skipped: tools\\claude-video\\skills\\watch not found.");
            return;
        }

        Directory.CreateDirectory(SkillsDir);
        Directory.CreateDirectory(CodexSkillsDir);
        try { CopyDir(skill, Path.Combine(SkillsDir, "watch")); SetupLog("  + Claude /watch skill"); }
        catch (Exception ex) { SetupLog("  x Claude /watch: " + ex.Message); }
        try { CopyDir(skill, Path.Combine(CodexSkillsDir, "watch")); SetupLog("  + Codex /watch skill"); }
        catch (Exception ex) { SetupLog("  x Codex /watch: " + ex.Message); }

        string claudeMarketplace = Path.Combine(HomeDir, ".claude", "plugins", "marketplaces", "claude-video");
        if (File.Exists(Path.Combine(root, ".claude-plugin", "plugin.json")) && !Directory.Exists(claudeMarketplace))
        {
            try { CopyDir(root, claudeMarketplace); SetupLog("  + Claude Video marketplace seeded"); } catch { }
        }

        if (HasCodex() && File.Exists(Path.Combine(root, ".agents", "plugins", "marketplace.json")))
        {
            if (!CodexMarketplaceConfigured("claude-video", root))
            {
                RunCodexCmd("plugin marketplace remove claude-video");
                RunCodexCmd("plugin marketplace add " + CmdQ(root));
            }
            RunCodexCmd("plugin add watch@claude-video");
        }
        SetupLog("OK  Claude Video /watch installed for Claude and Codex.");
        try { BeginInvoke((Action)LoadSkills); } catch { }
    }

    void InstallAgentSkillsIfPossible()
    {
        string src = FindToolsSource();
        if (src == null) { SetupLog("Agent Skills skipped: bundled tools folder not found."); return; }
        string root = Path.Combine(src, "agent-skills");
        string skillsRoot = Path.Combine(root, "skills");
        if (!Directory.Exists(skillsRoot) || !File.Exists(Path.Combine(root, ".codex-plugin", "plugin.json")))
        {
            SetupLog("Agent Skills skipped: tools\\agent-skills\\skills not found.");
            return;
        }

        Directory.CreateDirectory(SkillsDir);
        Directory.CreateDirectory(CodexSkillsDir);
        int copied = 0;
        foreach (string dir in Directory.GetDirectories(skillsRoot))
        {
            if (!File.Exists(Path.Combine(dir, "SKILL.md"))) continue;
            string name = new DirectoryInfo(dir).Name;
            bool ok = false;
            try { CopyDir(dir, Path.Combine(SkillsDir, name)); ok = true; } catch (Exception ex) { SetupLog("  x Claude " + name + ": " + ex.Message); }
            try { CopyDir(dir, Path.Combine(CodexSkillsDir, name)); ok = true; } catch (Exception ex) { SetupLog("  x Codex " + name + ": " + ex.Message); }
            if (ok) copied++;
        }

        string claudeMarketplace = Path.Combine(HomeDir, ".claude", "plugins", "marketplaces", "agent-skills");
        if (File.Exists(Path.Combine(root, ".claude-plugin", "plugin.json")) && !Directory.Exists(claudeMarketplace))
        {
            try { CopyDir(root, claudeMarketplace); SetupLog("  + Agent Skills marketplace seeded"); } catch { }
        }

        if (HasCodex() && File.Exists(Path.Combine(root, ".agents", "plugins", "marketplace.json")))
        {
            if (!CodexMarketplaceConfigured("agent-skills", root))
            {
                RunCodexCmd("plugin marketplace remove agent-skills");
                RunCodexCmd("plugin marketplace add " + CmdQ(root));
            }
            RunCodexCmd("plugin add agent-skills@agent-skills");
        }
        SetupLog("OK  Agent Skills installed for Claude and Codex (" + copied + " skills).");
        try { BeginInvoke((Action)LoadSkills); } catch { }
    }

    void InstallEverything()
    {
        SetupLog("");
        SetupLog("===== Installing everything (Node + Claude CLI + Codex CLI + RTK + Caveman + Claude Video + Agent Skills + skills) =====");
        if (!EnsureNode())
        {
            SetupLog("Node.js is required and could not be installed automatically. Fix that, then click Install everything again.");
            return;
        }
        InstallClaudeCli();
        InstallCodexCli();
        InstallRtk();
        InstallCaveman();
        InstallClaudeVideoIfPossible();
        InstallAgentSkillsIfPossible();
        string src = FindSkillsSource();
        if (src != null) DoInstallSkills(src);
        else SetupLog("No bundled skills found next to the app — use the Skills button to pick a folder.");
        SetupLog("===== Done. Restart any open Claude/Codex sessions to pick up new tools/skills. =====");
    }

    // Update the core packages in place to their latest versions. Assumes they're already
    // installed; installs on the fly if something is missing so it doubles as a repair.
    void UpdateCore()
    {
        SetupLog("");
        SetupLog("===== Updating core packages to latest =====");
        if (!EnsureNode()) return;
        SetupLog("> npm install -g npm@latest");
        RunLoggedCmd("npm install -g npm@latest");
        SetupLog("> updating Claude CLI (native installer, npm fallback)");
        int c = RunLoggedCmd(ClaudeInstallCmd());
        SetupLog(c == 0 ? "OK  Claude CLI up to date." : "Claude CLI update exit " + c + ".");
        SetupLog("> updating Codex CLI");
        int cx = RunLoggedCmd(CodexInstallCmd());
        SetupLog(cx == 0 ? "OK  Codex CLI up to date." : "Codex CLI update exit " + cx + ".");
        // RTK: pull the latest release binary again, then re-register the hook
        SetupLog("Updating RTK to the latest release…");
        RunPowerShellScript(RtkDownloadScript());
        RefreshPathFromRegistry();
        string rtk = File.Exists(RtkLocalPath()) ? "\"" + RtkLocalPath() + "\"" : "rtk";
        RunLoggedCmd(rtk + " init -g --auto-patch");
        RunLoggedCmd(rtk + " init -g --codex");
        try { BeginInvoke((Action)UpdateRtkStatus); } catch { }
        // Caveman: npx re-fetches the latest from GitHub each run
        SetupLog("Updating Caveman (npx pulls latest)…");
        RunLoggedCmd("npx -y github:JuliusBrussee/caveman --only claude --only codex");
        EnsureCodexCavemanInstructions();
        InstallBundledCavemanForCodexIfPossible();
        InstallClaudeVideoIfPossible();
        InstallAgentSkillsIfPossible();
        try { BeginInvoke((Action)(() => { UpdateCavemanStatus(); UpdateLaunchText(); })); } catch { }
        // Headroom is optional: only bump it if it's already present
        if (OnPath("headroom.exe") || OnPath("headroom"))
        {
            SetupLog("Updating Headroom…");
            if (OnPath("pipx")) RunLoggedCmd("pipx upgrade headroom-ai");
            else if (OnPath("uv")) RunLoggedCmd("uv tool upgrade headroom-ai");
            else if (OnPath("pip")) RunLoggedCmd("pip install --upgrade \"headroom-ai[all]\"");
        }
        SetupLog("===== Update complete. Restart any open Claude/Codex sessions. =====");
    }

    void RefreshRecent()
    {
        if (recentButton == null || recentMenu == null) return;
        recentMenu.Items.Clear();
        foreach (var path in GetRecent())
        {
            string recentPath = path;
            string project = path;
            try { project = new DirectoryInfo(path).Name; } catch { }
            var item = new ToolStripMenuItem(project + "  —  " + path) { ForeColor = Color.White, BackColor = Field };
            item.Click += (s, e) => { if (termPathBox != null) termPathBox.Text = recentPath; };
            recentMenu.Items.Add(item);
        }
        recentButton.Enabled = recentMenu.Items.Count > 0;
        recentButton.Text = recentMenu.Items.Count > 0 ? "Recent ▾" : "Recent";
    }
    void UpdateProxyStatus()
    {
        bool running = TestPort(ProxyPort);
        if (running) { hrStatus.Text = "● Headroom proxy: RUNNING on 127.0.0.1:" + ProxyPort; hrStatus.ForeColor = Green; }
        else { hrStatus.Text = "○ Headroom proxy: not running (auto-starts on launch)"; hrStatus.ForeColor = Yellow; }
        if (sidebarProxyStatus != null)
        {
            sidebarProxyStatus.Text = running ? "● Headroom proxy up" : "○ Proxy idle";
            sidebarProxyStatus.ForeColor = running ? Green : TextFaint;
        }
    }

    void UpdateSidebarCounts()
    {
        if (sidebarCounts != null)
            sidebarCounts.Text = CountSkills() + " skills · " + sessions.Count + " terminals";
    }
    void UpdateLaunchText()
    {
        string m = (modelCombo.Text ?? "").Trim(); if (m.Length == 0) m = "Default";
        string agent = (agentCombo != null && agentCombo.SelectedItem != null) ? agentCombo.SelectedItem.ToString() : "Claude";
        string tail = "";
        if (agent != "Codex" && hrCheck != null && hrCheck.Checked) tail += " +Headroom";
        if (rtCheck != null && rtCheck.Checked) tail += " +RTK";
        if (cvCheck != null && cvCheck.Checked) tail += " +Caveman";
        if (launchBtn != null)
        {
            string badges = "";
            if (agent != "Codex" && hrCheck != null && hrCheck.Checked) badges += "H";
            if (rtCheck != null && rtCheck.Checked) badges += (badges.Length > 0 ? "·" : "") + "R";
            if (cvCheck != null && cvCheck.Checked) badges += (badges.Length > 0 ? "·" : "") + "C";
            launchBtn.Text = "+ New" + (badges.Length > 0 ? "  (" + badges + ")" : "");
            if (tabTip == null) tabTip = new ToolTip { ShowAlways = true, InitialDelay = 250 };
            tabTip.SetToolTip(launchBtn, "Start an embedded " + agent + " session in the chosen folder.\nModel: " + m + (tail.Length > 0 ? "\nCompression:" + tail : "\nCompression: none"));
        }
    }

    // Advisory so the three tools never step on each other. They target different
    // config (Headroom=env, RTK=settings.json hook, Caveman=plugin) so they can't
    // corrupt one another — the only real gotcha is Headroom+RTK both compressing
    // shell output, which is redundant. Flag that; bless every other combo.
    void UpdateCompressionAdvisory()
    {
        if (compAdvisory == null) return;
        bool hr = hrCheck != null && hrCheck.Checked;
        bool rt = rtCheck != null && rtCheck.Checked;
        bool cv = cvCheck != null && cvCheck.Checked;
        if (hr && rt)
        {
            compAdvisory.Text = "⚠ Headroom + RTK both compress shell output — redundant. Pick one input tool (RTK for shell noise, Headroom for MCP/RAG/files).";
            compAdvisory.ForeColor = Yellow;
        }
        else if (!hr && !rt && !cv)
        {
            compAdvisory.Text = "No compression active. Tip: RTK (input) + Caveman (output) is the clean, non-overlapping combo.";
            compAdvisory.ForeColor = TextDim;
        }
        else
        {
            compAdvisory.Text = "Clean combo — these streams don't overlap." + ((rt || hr) && cv ? "  Input + output both covered." : "");
            compAdvisory.ForeColor = Green;
        }
    }

    // ================= Terminals + realtime alerts =================
    [DllImport("user32.dll")] static extern IntPtr SetParent(IntPtr hWndChild, IntPtr hWndNewParent);
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr hwnd, IntPtr hdcBlt, uint flags);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
    [DllImport("user32.dll")] static extern bool MoveWindow(IntPtr hWnd, int x, int y, int w, int h, bool repaint);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
    [DllImport("user32.dll")] static extern IntPtr SetFocus(IntPtr hWnd);
    [DllImport("user32.dll")] static extern IntPtr SetActiveWindow(IntPtr hWnd);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr hWnd, StringBuilder cn, int max);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hWnd);
    const int GWL_STYLE = -16;
    const int WS_CHILD = 0x40000000, WS_CAPTION = 0x00C00000, WS_THICKFRAME = 0x00040000,
              WS_MINIMIZE = 0x20000000, WS_MAXIMIZE = 0x01000000, WS_BORDER = 0x00800000,
              WS_VISIBLE = 0x10000000;
    const int SW_HIDE = 0, SW_SHOW = 5;

    // ---- process-tree walking (the console window belongs to a CHILD of the conhost we launch) ----
    [DllImport("kernel32.dll")] static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint pid);
    [DllImport("kernel32.dll")] static extern bool Process32First(IntPtr snap, ref PROCESSENTRY32 pe);
    [DllImport("kernel32.dll")] static extern bool Process32Next(IntPtr snap, ref PROCESSENTRY32 pe);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    const uint TH32CS_SNAPPROCESS = 2;
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
    struct PROCESSENTRY32
    {
        public uint dwSize, cntUsage, th32ProcessID;
        public IntPtr th32DefaultHeapID;
        public uint th32ModuleID, cntThreads, th32ParentProcessID;
        public int pcPriClassBase;
        public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szExeFile;
    }

    static HashSet<uint> DescendantPids(int root)
    {
        var set = new HashSet<uint> { (uint)root };
        var parentOf = new Dictionary<uint, uint>();
        IntPtr snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if (snap == IntPtr.Zero || snap == new IntPtr(-1)) return set;
        try
        {
            var pe = new PROCESSENTRY32 { dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32)) };
            if (Process32First(snap, ref pe))
                do { parentOf[pe.th32ProcessID] = pe.th32ParentProcessID; } while (Process32Next(snap, ref pe));
        }
        finally { CloseHandle(snap); }
        // add any pid whose ancestry chain reaches root
        foreach (var pid in parentOf.Keys)
        {
            uint cur = pid; int guard = 0;
            while (cur != 0 && guard++ < 64)
            {
                if (cur == (uint)root) { set.Add(pid); break; }
                if (!parentOf.TryGetValue(cur, out cur)) break;
            }
        }
        return set;
    }

    // Find the classic console window owned by the launched process OR any descendant.
    static IntPtr FindConsoleWindow(int rootPid)
    {
        var pids = DescendantPids(rootPid);
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) =>
        {
            if (!IsWindowVisible(h)) return true;
            uint wpid; GetWindowThreadProcessId(h, out wpid);
            if (!pids.Contains(wpid)) return true;
            var cn = new StringBuilder(64); GetClassName(h, cn, 64);
            if (cn.ToString() == "ConsoleWindowClass") { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    class TermSession
    {
        public string Id, Name, Folder, Agent = "Claude", Model = "Default", Task = "Interactive session", Status = TermReady;
        public string CodexProfilePath;
        public Color Color = Color.Gray;
        public Process Proc;
        public IntPtr Hwnd = IntPtr.Zero;
        public bool Embedded;
        public bool Popped;
        // token-compression tools captured at launch, so each session shows its own mix
        public bool CHeadroom, CRtk, CCaveman;
    }

    // Flicker-free, fully owner-drawn button (used for the rich terminal tabs).
    class DrawButton : Button
    {
        public Action<Graphics, Rectangle> Painter;
        public DrawButton()
        {
            SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint |
                     ControlStyles.AllPaintingInWmPaint | ControlStyles.ResizeRedraw, true);
            FlatStyle = FlatStyle.Flat;
            FlatAppearance.BorderSize = 0;
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            if (Painter != null) Painter(e.Graphics, ClientRectangle);
            if (Focused) ControlPaint.DrawFocusRectangle(e.Graphics, new Rectangle(4, 4, Width - 8, Height - 8), Color.White, Color.Transparent);
        }
    }

    void BuildTerminalsTab(Control tab)
    {
        // Deterministic docked layout so nothing ever overlaps regardless of width.
        // Row 0: compact toolbar (fixed height).  Row 1: session tab strip.  Row 2: terminal host (fills).
        var root = new TableLayoutPanel {
            Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 3,
            BackColor = Color.Transparent, Padding = new Padding(16, 12, 16, 16) };
        terminalRoot = root;
        root.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100f));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 40f));   // toolbar
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 8f));    // expands to 70px when sessions exist
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100f));   // terminal host
        tab.Controls.Add(root);

        // ---- toolbar: New | folder path | Recent ▾ | Browse | Close | Pop out ----
        var bar = new TableLayoutPanel {
            Dock = DockStyle.Fill, ColumnCount = 7, RowCount = 1, BackColor = Color.Transparent, Margin = new Padding(0) };
        bar.RowStyles.Add(new RowStyle(SizeType.Percent, 100f));
        bar.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 112f)); // Agent
        bar.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 126f)); // New + compression badges
        bar.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100f));  // path (stretches)
        bar.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 132f)); // recent combo
        bar.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 72f));  // Browse
        bar.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 58f));  // Close
        bar.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 66f));  // Pop out
        root.Controls.Add(bar, 0, 0);

        // Mac-style segmented agent picker; keep an invisible ComboBox as the existing
        // settings synchronization boundary so launch behavior stays unchanged.
        var agentPick = new ComboBox { Visible = false, DropDownStyle = ComboBoxStyle.DropDownList };
        agentPick.Items.AddRange(new object[] { "Claude", "Codex" });
        agentPick.SelectedItem = agentCombo != null ? agentCombo.SelectedItem : "Claude";
        termAgentCombo = agentPick;
        var segment = new Panel { Dock = DockStyle.Fill, Margin = new Padding(0, 6, 8, 6), BackColor = Field };
        RoundRegion(segment, 7);
        var claudeSegment = new Button { Text = "Claude", FlatStyle = FlatStyle.Flat, Location = new Point(0, 0),
            Size = new Size(52, 28), TextAlign = ContentAlignment.MiddleCenter, Cursor = Cursors.Hand, TabStop = true };
        var codexSegment = new Button { Text = "Codex", FlatStyle = FlatStyle.Flat, Location = new Point(52, 0),
            Size = new Size(52, 28), TextAlign = ContentAlignment.MiddleCenter, Cursor = Cursors.Hand, TabStop = true };
        claudeSegment.FlatAppearance.BorderSize = 0;
        codexSegment.FlatAppearance.BorderSize = 0;
        Action syncSegments = () => {
            bool claude = (agentPick.SelectedItem ?? "Claude").ToString() != "Codex";
            claudeSegment.BackColor = claude ? FieldHi : Field;
            codexSegment.BackColor = claude ? Field : FieldHi;
            claudeSegment.ForeColor = claude ? Color.White : TextDim;
            codexSegment.ForeColor = claude ? TextDim : Color.White;
            claudeSegment.Font = new Font("Segoe UI", 8f, claude ? FontStyle.Bold : FontStyle.Regular);
            codexSegment.Font = new Font("Segoe UI", 8f, claude ? FontStyle.Regular : FontStyle.Bold);
        };
        claudeSegment.Click += (s, e) => agentPick.SelectedItem = "Claude";
        codexSegment.Click += (s, e) => agentPick.SelectedItem = "Codex";
        agentPick.SelectedIndexChanged += (s, e) => {
            syncSegments();
            if (agentCombo != null && agentCombo.SelectedItem != agentPick.SelectedItem) agentCombo.SelectedItem = agentPick.SelectedItem;
        };
        segment.Controls.Add(claudeSegment);
        segment.Controls.Add(codexSegment);
        syncSegments();
        bar.Controls.Add(segment, 0, 0);

        var newBtn = AccentBtn("+ New");
        newBtn.Dock = DockStyle.Fill; newBtn.Margin = new Padding(0, 4, 8, 4);
        newBtn.Click += (s, e) => NewTerminal(termPathBox.Text);
        bar.Controls.Add(newBtn, 1, 0);
        launchBtn = newBtn;   // UpdateLaunchText keeps its caption in sync with model + compression

        string startFolder = (pathBox != null && Directory.Exists(pathBox.Text)) ? pathBox.Text : HomeDir;
        // Single-line TextBox ignores Dock=Fill width in a TLP cell — anchor L|R to stretch reliably.
        termPathBox = new TextBox { Anchor = AnchorStyles.Left | AnchorStyles.Right, Height = 26, Margin = new Padding(0, 7, 8, 7),
            BackColor = Panel2, ForeColor = Color.White, BorderStyle = BorderStyle.FixedSingle, Text = startFolder };
        bar.Controls.Add(termPathBox, 2, 0);
        pathBox = termPathBox;   // single source of truth for the launch folder

        // Match the Mac clock menu instead of using native ComboBox chrome, which
        // renders a bright white arrow surface under Windows visual styles.
        recentMenu = new ContextMenuStrip { BackColor = Field, ForeColor = Color.White, ShowImageMargin = false };
        recentButton = GhostBtn("Recent");
        recentButton.Dock = DockStyle.Fill;
        recentButton.Margin = new Padding(0, 4, 8, 4);
        recentButton.Click += (s, e) => {
            if (recentMenu.Items.Count > 0) recentMenu.Show(recentButton, new Point(0, recentButton.Height));
        };
        if (tabTip == null) tabTip = new ToolTip { ShowAlways = true, InitialDelay = 250 };
        tabTip.SetToolTip(recentButton, "Recent project folders");
        bar.Controls.Add(recentButton, 3, 0);

        var browseBtn = GhostBtn("Browse…");
        browseBtn.Dock = DockStyle.Fill; browseBtn.Margin = new Padding(0, 4, 8, 4);
        browseBtn.Click += (s, e) => {
            using (var dlg = new FolderBrowserDialog { Description = "Folder for the next Claude session", ShowNewFolderButton = true })
            { if (Directory.Exists(termPathBox.Text)) dlg.SelectedPath = termPathBox.Text; if (dlg.ShowDialog() == DialogResult.OK) termPathBox.Text = dlg.SelectedPath; }
        };
        bar.Controls.Add(browseBtn, 4, 0);

        var closeBtn = DangerBtn("Close");
        closeBtn.Dock = DockStyle.Fill; closeBtn.Margin = new Padding(0, 4, 8, 4);
        closeBtn.Click += (s, e) => CloseSelectedTerminal();
        bar.Controls.Add(closeBtn, 5, 0);

        var focusBtn = GhostBtn("Pop out");
        focusBtn.Dock = DockStyle.Fill; focusBtn.Margin = new Padding(0, 4, 0, 4);
        focusBtn.Click += (s, e) => FocusSelectedTerminal();
        bar.Controls.Add(focusBtn, 6, 0);

        // ---- browser-style tab strip: one switchable tab per running session ----
        termTabs = new FlowLayoutPanel {
            Dock = DockStyle.Fill, Margin = new Padding(0, 4, 0, 4),
            FlowDirection = FlowDirection.LeftToRight, WrapContents = false, AutoScroll = true,
            BackColor = Color.Transparent, Padding = new Padding(0), Visible = false };
        root.Controls.Add(termTabs, 0, 1);

        // ---- terminal host fills the remaining space ----
        termHost = new Panel { Dock = DockStyle.Fill, Margin = new Padding(0, 4, 0, 0),
            BackColor = Color.FromArgb(16, 16, 18), BorderStyle = BorderStyle.FixedSingle };
        RoundRegion(termHost, 12);
        termHost.Resize += (s, e) => ResizeEmbedded();
        root.Controls.Add(termHost, 0, 2);

        termEmptyState = new Panel { Dock = DockStyle.Fill, BackColor = Color.FromArgb(16, 16, 18) };
        var empty = new Panel { Size = new Size(590, 170), BackColor = Color.Transparent };
        Action centerEmpty = () => empty.Location = new Point(Math.Max(0, (termEmptyState.ClientSize.Width - empty.Width) / 2),
                                                               Math.Max(0, (termEmptyState.ClientSize.Height - empty.Height) / 2));
        termEmptyState.Resize += (s, e) => centerEmpty();
        empty.Controls.Add(new Label { Text = ">_", Location = new Point(0, 4), Size = new Size(590, 38),
            TextAlign = ContentAlignment.MiddleCenter, ForeColor = TextFaint, Font = new Font("Consolas", 19f, FontStyle.Bold) });
        empty.Controls.Add(new Label { Text = "No terminals yet", Location = new Point(0, 49), Size = new Size(590, 24),
            TextAlign = ContentAlignment.MiddleCenter, ForeColor = TextDim, Font = new Font("Segoe UI Semibold", 11f, FontStyle.Bold) });
        empty.Controls.Add(new Label { Text = "Click “+ New” to start a Claude or Codex session. It runs right here as a tab —\r\nopen as many as you like and switch between them.",
            Location = new Point(0, 79), Size = new Size(590, 42), TextAlign = ContentAlignment.MiddleCenter,
            ForeColor = TextFaint, Font = new Font("Segoe UI", 8.5f) });
        empty.Controls.Add(new Label { Text = "H Headroom · R RTK · C Caveman   ·   Ctrl+T new terminal", Location = new Point(0, 132), Size = new Size(590, 20),
            TextAlign = ContentAlignment.MiddleCenter, ForeColor = TextFaint, Font = new Font("Segoe UI", 8f) });
        termEmptyState.Controls.Add(empty);
        centerEmpty();
        termHost.Controls.Add(termEmptyState);
    }

    static string JEsc(string s) { return s.Replace("\\", "\\\\").Replace("\"", "\\\""); }

    string WriteSessionSettings(string id, bool rtk, bool caveman)
    {
        string exe = Application.ExecutablePath;
        Func<string, string> cmd = ev => JEsc("\"" + exe + "\" --hook " + ev + " --session " + id);
        var sb = new StringBuilder();
        sb.Append("{\n  \"hooks\": {\n");
        sb.Append("    \"SessionStart\":     [{\"hooks\":[{\"type\":\"command\",\"command\":\"" + cmd("ready") + "\"}]}],\n");
        sb.Append("    \"UserPromptSubmit\": [{\"hooks\":[{\"type\":\"command\",\"command\":\"" + cmd("work") + "\"}]}],\n");
        sb.Append("    \"Notification\":     [{\"matcher\":\"permission_prompt|idle_prompt|elicitation_dialog\",\"hooks\":[{\"type\":\"command\",\"command\":\"" + cmd("notify") + "\"}]}],\n");
        sb.Append("    \"Stop\":             [{\"hooks\":[{\"type\":\"command\",\"command\":\"" + cmd("stop") + "\"}]}],\n");
        sb.Append("    \"StopFailure\":      [{\"hooks\":[{\"type\":\"command\",\"command\":\"" + cmd("failure") + "\"}]}]");
        // RTK (input compression) is a global PreToolUse hook. Claude MERGES hooks across
        // settings sources and DEDUPES identical commands, so re-declaring it here guarantees it
        // runs in this embedded session and makes the per-terminal RTK toggle meaningful — never
        // double-compressing. On Windows the CLI issues shell commands through the PowerShell
        // tool (not Bash), so the matcher must cover both or RTK never fires.
        if (rtk)
            sb.Append(",\n    \"PreToolUse\": [{\"matcher\":\"Bash|PowerShell\",\"hooks\":[{\"type\":\"command\",\"command\":\"rtk hook claude\"}]}]");
        sb.Append("\n  }");
        // Plugin enabled state is not guaranteed to merge from user settings when we pass
        // --settings, so declare required plugins per-session.
        bool agentSkills = AgentSkillsInstalled();
        if (caveman || agentSkills)
        {
            sb.Append(",\n  \"extraKnownMarketplaces\": {");
            bool first = true;
            if (caveman)
            {
                sb.Append("\"caveman\":{\"source\":{\"source\":\"github\",\"repo\":\"JuliusBrussee/caveman\"}}");
                first = false;
            }
            if (agentSkills)
            {
                if (!first) sb.Append(",");
                sb.Append("\"addy-agent-skills\":{\"source\":{\"source\":\"github\",\"repo\":\"addyosmani/agent-skills\"}}");
            }
            sb.Append("}");
            sb.Append(",\n  \"enabledPlugins\": {");
            first = true;
            if (caveman)
            {
                sb.Append("\"caveman@caveman\":true");
                first = false;
            }
            if (agentSkills)
            {
                if (!first) sb.Append(",");
                sb.Append("\"agent-skills@addy-agent-skills\":true");
            }
            sb.Append("}");
        }
        sb.Append("\n}\n");
        string path = Path.Combine(SessDir, id + ".settings.json");
        File.WriteAllText(path, sb.ToString());
        return path;
    }

    static string TomlEsc(string s)
    {
        return (s ?? "").Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\r", "\\r").Replace("\n", "\\n");
    }

    string WriteCodexSessionProfile(string id, out string path)
    {
        string name = "hydra-" + id;
        path = Path.Combine(CodexDir, name + ".config.toml");
        string exe = (Application.ExecutablePath ?? "").Replace("'", "''");
        Func<string, bool, string> command = (ev, json) => {
            string script = "& '" + exe + "' --hook " + ev + " --session " + id;
            if (json) script += "; Write-Output '{}'";
            return "powershell.exe -NoProfile -Command \"" + script.Replace("\"", "\\\"") + "\"";
        };
        var sb = new StringBuilder();
        Action<string, string, bool> add = (hook, ev, json) => {
            sb.Append("[[hooks." + hook + "]]\n");
            sb.Append("[[hooks." + hook + ".hooks]]\n");
            sb.Append("type = \"command\"\n");
            sb.Append("command = \"" + TomlEsc(command(ev, json)) + "\"\n");
            sb.Append("command_windows = \"" + TomlEsc(command(ev, json)) + "\"\n");
            sb.Append("timeout = 5\n\n");
        };
        add("SessionStart", "ready", false);
        add("UserPromptSubmit", "work", false);
        add("PermissionRequest", "notify", false);
        add("Stop", "stop", true);
        Directory.CreateDirectory(CodexDir);
        File.WriteAllText(path, sb.ToString());
        return name;
    }

    // Auto-trust: mark a folder as trusted in ~/.claude.json so the CLI never shows the
    // "Do you trust the files in this folder?" prompt for workspace sessions. Surgical,
    // backed-up string edit (no JSON parser in .NET 4; the file has empty-string keys
    // that break ConvertFrom-Json anyway). Existing entry => flip the flag; missing entry
    // => prepend a trusted entry to the projects object.
    void TrustFolder(string folder)
    {
        try
        {
            if (string.IsNullOrEmpty(folder)) return;
            string cfg = Path.Combine(HomeDir, ".claude.json");
            if (!File.Exists(cfg)) return;   // CLI will create it and prompt once; nothing safe to do yet
            string key = folder.Replace('\\', '/').TrimEnd('/');
            string keyTok = "\"" + key + "\"";
            string text = File.ReadAllText(cfg);

            int ki = text.IndexOf(keyTok, StringComparison.Ordinal);
            string updated = null;
            if (ki >= 0)
            {
                const string field = "\"hasTrustDialogAccepted\":";
                int fi = text.IndexOf(field, ki, StringComparison.Ordinal);
                if (fi < 0) return;
                int vs = fi + field.Length;
                int ve = vs;
                while (ve < text.Length && text[ve] != ',' && text[ve] != '}') ve++;
                if (text.Substring(vs, ve - vs).Trim() == "true") return;   // already trusted
                updated = text.Substring(0, vs) + "true" + text.Substring(ve);
            }
            else
            {
                int pi = text.IndexOf("\"projects\":", StringComparison.Ordinal);
                if (pi < 0) return;
                int brace = text.IndexOf('{', pi);
                if (brace < 0) return;
                int after = brace + 1;
                int p = after;
                while (p < text.Length && char.IsWhiteSpace(text[p])) p++;
                bool empty = p < text.Length && text[p] == '}';
                string entry = keyTok + ":{\"allowedTools\":[],\"hasTrustDialogAccepted\":true,\"projectOnboardingSeenCount\":1}";
                string ins = empty ? entry : entry + ",";
                updated = text.Substring(0, after) + ins + text.Substring(after);
            }
            if (updated == null) return;
            try { File.Copy(cfg, cfg + ".cmbak", true); } catch { }
            File.WriteAllText(cfg, updated);
        }
        catch { }
    }

    void NewTerminal() { NewTerminal(null); }
    void NewTerminal(string presetFolder)
    {
        string folder;
        if (!string.IsNullOrEmpty(presetFolder) && Directory.Exists(presetFolder))
        {
            folder = presetFolder;
        }
        else
        {
            folder = pathBox != null && Directory.Exists(pathBox.Text) ? pathBox.Text : HomeDir;
            using (var dlg = new FolderBrowserDialog { Description = "Folder for this Claude session", ShowNewFolderButton = true, SelectedPath = folder })
            {
                if (dlg.ShowDialog() != DialogResult.OK) return;
                folder = dlg.SelectedPath;
            }
        }
        bool useHeadroom = hrCheck != null && hrCheck.Checked;
        string agent = (agentCombo != null && agentCombo.SelectedItem != null) ? agentCombo.SelectedItem.ToString() : "Claude";
        if (agent != "Codex") TrustFolder(folder);   // Claude trust prompt is noisy inside embedded terminals
        if (agent != "Codex" && useHeadroom && !EnsureProxy()) return;

        string id = Guid.NewGuid().ToString("N").Substring(0, 12);
        bool useRtk = rtCheck != null && rtCheck.Checked;
        bool useCaveman = cvCheck != null && cvCheck.Checked;

        string selectedModel = (modelCombo.Text ?? "").Trim();
        string model = CliModelName(selectedModel);
        string extra = (extraBox.Text ?? "").Trim();
        string cmd;
        string codexProfilePath = null;
        if (agent == "Codex")
        {
            EnsureCodexCompressionForLaunch(useRtk, useCaveman);
            string profile = WriteCodexSessionProfile(id, out codexProfilePath);
            cmd = "codex --profile " + CmdQ(profile) + " --enable hooks --dangerously-bypass-hook-trust -C " + CmdQ(folder);
            if (model.Length > 0 && model != "Default") cmd += " --model " + CmdQ(model);
            cmd += CodexPermFlag();
            if (extra.Length > 0) cmd += " " + extra;
            if (continueChk.Checked) cmd += " resume --last";
        }
        else
        {
            string settings = WriteSessionSettings(id, useRtk, useCaveman);
            cmd = "claude --settings \"" + settings + "\"";
            if (model.Length > 0 && model != "Default") cmd += " --model " + model;
            cmd += PermFlag();
            if (continueChk.Checked) cmd += " --continue";
            if (extra.Length > 0) cmd += " " + extra;
        }

        string task = TaskLabelForLaunch(extra, continueChk.Checked);
        var sess = new TermSession { Id = id, Folder = folder,
            Agent = agent,
            Model = SessionModelLabel(model),
            Task = task,
            Name = TabHint(task, folder),
            CHeadroom = agent == "Codex" ? false : useHeadroom,
            CRtk = useRtk,
            CCaveman = useCaveman,
            CodexProfilePath = codexProfilePath };
        try
        {
            // Force a CLASSIC conhost window (bypass Windows Terminal, which cannot be reparented).
            // conhost.exe launches the command in a legacy console we own and can embed.
            string exitHook = "\"" + Application.ExecutablePath + "\" --hook exited --session " + id;
            var psi = new ProcessStartInfo("conhost.exe", "cmd.exe /k title " + agent + " " + id + " & " + cmd + " & " + exitHook)
            { UseShellExecute = false, CreateNoWindow = false, WorkingDirectory = folder };
            psi.EnvironmentVariables["CODEX_HOME"] = CodexDir;
            if (agent != "Codex" && useHeadroom) psi.EnvironmentVariables["ANTHROPIC_BASE_URL"] = "http://127.0.0.1:" + ProxyPort;
            sess.Proc = Process.Start(psi);
        }
        catch (Exception ex)
        {
            MessageBox.Show("Failed to start terminal:\n" + ex.Message, "Hydra", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }
        // Start idle: Claude boots to a prompt and waits for you. The tab only spins once
        // the UserPromptSubmit hook fires ("work"); the Stop hook returns it to idle.
        sess.Status = TermReady; sess.Color = Green;
        sessions.Add(sess);
        SaveRecent(folder);
        RefreshRecent();
        selectedTerm = sess;          // focus the freshly opened tab
        RefreshTermList();
        ShowSelectedTerminal();
    }

    string SessionModelLabel(string model)
    {
        string m = (model ?? "").Trim();
        return m.Length == 0 || string.Equals(m, "Default", StringComparison.OrdinalIgnoreCase) ? "Resolving model…" : m;
    }

    string TabHint(string task, string folder)
    {
        string value = (task ?? "").Trim();
        if (value.Length > 0 && !string.Equals(value, "Interactive session", StringComparison.OrdinalIgnoreCase)) return value;
        try
        {
            string project = new DirectoryInfo(folder).Name;
            return string.IsNullOrWhiteSpace(project) ? "Workspace" : project;
        }
        catch { return "Workspace"; }
    }

    string TaskLabelForLaunch(string extra, bool resume)
    {
        string p = Regex.Replace((extra ?? "").Trim().Trim('"', '\''), "\\s+", " ");
        if (p.Length == 0) return resume ? "Resume last session" : "Interactive session";
        string l = p.ToLowerInvariant();
        if (l.Contains("complete saas") || l.Contains("vision.md")) return "Build SaaS";
        if (l.Contains("deploy.md") || l.Contains("deployed to")) return "Deploy project";
        if (l.Contains("subscriptions.md") || l.Contains("subscription infrastructure")) return "Implement billing";
        if (l.Contains("playbook.md")) return "Run project mission";
        return p.Length <= 42 ? p : p.Substring(0, 41) + "…";
    }

    TermSession SelectedSession()
    {
        if (selectedTerm != null && sessions.Contains(selectedTerm)) return selectedTerm;
        return null;
    }

    void SelectTerm(TermSession s)
    {
        selectedTerm = s;
        RefreshTermList();
        ShowSelectedTerminal();
    }

    void EmbedIfReady(TermSession s)
    {
        if (s.Embedded || s.Popped || s.Proc == null) return;
        try
        {
            if (s.Proc.HasExited) return;
            // The console window is owned by the conhost process we started; find it by class+pid.
            IntPtr h = FindConsoleWindow(s.Proc.Id);
            if (h == IntPtr.Zero) return;   // console not created yet — try again next tick
            int style = GetWindowLong(h, GWL_STYLE);
            style = (style | WS_CHILD | WS_VISIBLE) & ~(WS_CAPTION | WS_THICKFRAME | WS_MINIMIZE | WS_MAXIMIZE | WS_BORDER);
            SetWindowLong(h, GWL_STYLE, style);
            SetParent(h, termHost.Handle);
            s.Hwnd = h;
            s.Embedded = true;
            ShowWindow(h, SelectedSession() == s ? SW_SHOW : SW_HIDE);
            if (SelectedSession() == s) { ResizeEmbedded(); FocusConsole(h); }
        }
        catch { }
    }

    // Cross-process keyboard focus: a reparented conhost window belongs to another
    // thread, so a plain click won't give it keyboard focus. Attach our input queue
    // to the console thread, SetFocus the console HWND, then detach.
    void FocusConsole(IntPtr h)
    {
        if (h == IntPtr.Zero) return;
        try
        {
            uint tpid;
            uint conThread = GetWindowThreadProcessId(h, out tpid);
            uint guiThread = GetCurrentThreadId();
            bool attached = conThread != guiThread && AttachThreadInput(guiThread, conThread, true);
            try { SetForegroundWindow(this.Handle); SetFocus(h); SetActiveWindow(h); }
            finally { if (attached) AttachThreadInput(guiThread, conThread, false); }
        }
        catch { }
    }

    void ShowSelectedTerminal()
    {
        var sel = SelectedSession();
        if (termEmptyState != null) termEmptyState.Visible = sel == null;
        foreach (var s in sessions)
            if (s.Embedded && s.Hwnd != IntPtr.Zero)
                ShowWindow(s.Hwnd, s == sel ? SW_SHOW : SW_HIDE);
        if (sel != null) { EmbedIfReady(sel); ResizeEmbedded(); if (sel.Embedded) FocusConsole(sel.Hwnd); }
    }

    void ResizeEmbedded()
    {
        var sel = SelectedSession();
        if (sel != null && sel.Embedded && sel.Hwnd != IntPtr.Zero)
            MoveWindow(sel.Hwnd, 0, 0, termHost.ClientSize.Width, termHost.ClientSize.Height, true);
    }

    void FocusSelectedTerminal()
    {
        var s = SelectedSession();
        if (s == null || s.Hwnd == IntPtr.Zero) return;
        // detach back to desktop so it becomes a normal window again
        try
        {
            SetParent(s.Hwnd, IntPtr.Zero);
            int style = GetWindowLong(s.Hwnd, GWL_STYLE);
            style = (style & ~WS_CHILD) | WS_CAPTION | WS_THICKFRAME;
            SetWindowLong(s.Hwnd, GWL_STYLE, style);
            MoveWindow(s.Hwnd, 120, 120, 900, 560, true);
            ShowWindow(s.Hwnd, SW_SHOW);
            SetForegroundWindow(s.Hwnd);
            s.Embedded = false; s.Popped = true; // now a free-floating window; TermTick leaves it alone
        }
        catch { }
    }

    void CloseSelectedTerminal()
    {
        var s = SelectedSession(); if (s == null) return;
        if (s.Status == TermWorking &&
            MessageBox.Show("Session '" + s.Name.Trim() + "' is still WORKING.\nClose it anyway?", "Hydra",
                MessageBoxButtons.YesNo, MessageBoxIcon.Warning) != DialogResult.Yes) return;
        KillSession(s); RefreshTermList(); ShowSelectedTerminal();
    }

    void KillSession(TermSession s)
    {
        try { if (s.Proc != null && !s.Proc.HasExited) { var p = new ProcessStartInfo("taskkill", "/PID " + s.Proc.Id + " /T /F") { UseShellExecute = false, CreateNoWindow = true }; Process.Start(p); } }
        catch { }
        try { File.Delete(Path.Combine(SessDir, s.Id + ".settings.json")); } catch { }
        try { if (!string.IsNullOrEmpty(s.CodexProfilePath)) File.Delete(s.CodexProfilePath); } catch { }
        sessions.Remove(s);
    }

    void RefreshTermList()
    {
        if (termTabs == null) return;
        if (selectedTerm != null && !sessions.Contains(selectedTerm)) selectedTerm = null;
        if (selectedTerm == null && sessions.Count > 0) selectedTerm = sessions[sessions.Count - 1];

        termTabs.SuspendLayout();
        foreach (Control c in termTabs.Controls) c.Dispose();
        termTabs.Controls.Clear();
        foreach (var s in sessions)
        {
            var cur = s;
            var tabBtn = new DrawButton {
                Tag = s, AutoSize = false, Size = new Size(230, 58),
                Margin = new Padding(0, 3, 6, 3), Cursor = Cursors.Hand, TabStop = true };
            RoundRegion(tabBtn, 8);
            tabBtn.Painter = (g, rect) => PaintTermTab(g, rect, cur, cur == selectedTerm);
            tabBtn.MouseUp += (a, e) => {
                if (e.Button != MouseButtons.Left) return;
                if (e.Button == MouseButtons.Left && e.X >= tabBtn.Width - 30)
                {
                    selectedTerm = cur;
                    CloseSelectedTerminal();
                }
                else SelectTerm(cur);
            };
            tabBtn.KeyDown += (a, e) => {
                if (e.KeyCode == Keys.Enter || e.KeyCode == Keys.Space)
                {
                    SelectTerm(cur);
                    e.SuppressKeyPress = true;
                }
                else if (e.KeyCode == Keys.Delete || (e.Control && e.KeyCode == Keys.W))
                {
                    selectedTerm = cur;
                    CloseSelectedTerminal();
                    e.SuppressKeyPress = true;
                }
            };
            if (tabTip == null) tabTip = new ToolTip { ShowAlways = true, InitialDelay = 250 };
            tabTip.SetToolTip(tabBtn, TermTipText(cur));
            termTabs.Controls.Add(tabBtn);
        }
        termTabs.ResumeLayout();
        bool hasTabs = sessions.Count > 0;
        termTabs.Visible = hasTabs;
        if (terminalRoot != null && terminalRoot.RowStyles.Count > 1)
        {
            terminalRoot.RowStyles[1].Height = hasTabs ? 70f : 8f;
            terminalRoot.PerformLayout();
        }
        UpdateSidebarCounts();
    }

    // Mac-parity terminal chip: task + runtime model on top, live status below,
    // close action at right. Compression and folder details remain in the tooltip.
    void PaintTermTab(Graphics g, Rectangle rect, TermSession s, bool on)
    {
        g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
        g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;

        Color bg = on ? Lerp(Field, Accent, 0.20f) : Field;
        using (var b = new SolidBrush(bg)) g.FillRectangle(b, rect);

        bool live = s.Status == TermWorking;
        int cx = 14, cy = 17;

        if (live)
        {
            float sweepStart = (float)((animT * 220) % 360);
            using (var pen = new Pen(s.Color, 2f))
            {
                pen.StartCap = System.Drawing.Drawing2D.LineCap.Round;
                pen.EndCap = System.Drawing.Drawing2D.LineCap.Round;
                g.DrawArc(pen, cx - 5, cy - 5, 10, 10, sweepStart, 270);
            }
        }
        else
        {
            using (var b = new SolidBrush(s.Color)) g.FillEllipse(b, cx - 4, cy - 4, 8, 8);
        }

        int tx = 26;
        string hint = TabHint(s.Task, s.Folder);
        using (var f = new Font("Segoe UI Semibold", 9.2f, FontStyle.Bold))
        using (var b = new SolidBrush(on ? Color.White : Color.FromArgb(222, 222, 228)))
        using (var sf = new StringFormat { Trimming = StringTrimming.EllipsisCharacter, FormatFlags = StringFormatFlags.NoWrap })
            g.DrawString(hint, f, b, new RectangleF(tx, 6, 92, 18), sf);

        using (var f = new Font("Consolas", 8f))
        using (var b = new SolidBrush(on ? Accent : TextFaint))
        using (var sf = new StringFormat { Trimming = StringTrimming.EllipsisCharacter, FormatFlags = StringFormatFlags.NoWrap })
            g.DrawString(SessionModelLabel(s.Model), f, b, new RectangleF(121, 7, rect.Width - 151, 18), sf);

        using (var f = new Font("Segoe UI", 8f, FontStyle.Bold))
        using (var b = new SolidBrush(TextFaint))
        using (var sf = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center })
            g.DrawString("×", f, b, new RectangleF(rect.Width - 26, 5, 20, 20), sf);

        string status = string.IsNullOrWhiteSpace(s.Status) ? TermReady : s.Status.Trim();
        using (var f = new Font("Segoe UI", 8.8f, FontStyle.Bold))
        using (var b = new SolidBrush(s.Color))
        using (var sf = new StringFormat { Trimming = StringTrimming.EllipsisCharacter, FormatFlags = StringFormatFlags.NoWrap })
            g.DrawString(status, f, b, new RectangleF(tx, 31, rect.Width - tx - 12, 18), sf);

        using (var pen = new Pen(on ? Color.FromArgb(130, Accent) : Color.FromArgb(48, 255, 255, 255), on ? 1.3f : 1f))
        using (var path = RoundedPath(new Rectangle(0, 0, rect.Width - 1, rect.Height - 1), 8))
            g.DrawPath(pen, path);
    }

    // Plain-language per-session compression summary, shown on tab hover.
    string TermTipText(TermSession s)
    {
        var on = new List<string>();
        if (s.CHeadroom) on.Add("Headroom (proxy compresses tool output & context)");
        if (s.CRtk) on.Add("RTK (filters shell/test/build output)");
        if (s.CCaveman) on.Add("Caveman (compresses " + s.Agent + "'s replies)");
        string head = AgentLabel(s.Agent) + "\nModel: " + SessionModelLabel(s.Model) + "\nTask: " + (string.IsNullOrWhiteSpace(s.Task) ? "Interactive session" : s.Task.Trim()) + "\nFolder: " + s.Folder + "\nStatus: " + s.Status;
        if (on.Count == 0) return head + "\n\nToken compression: none enabled for this session";
        return head + "\n\nToken compression enabled:\n • " + string.Join("\n • ", on.ToArray());
    }

    string AgentLabel(string agent)
    {
        return agent == "Codex" ? "ChatGPT/Codex" : (string.IsNullOrWhiteSpace(agent) ? "Claude" : agent);
    }

    void TermTick()
    {
        bool changed = false;
        foreach (var s in sessions)
        {
            if (!s.Embedded) EmbedIfReady(s);
            if (s.Proc != null && s.Proc.HasExited && s.Status != TermStopped)
            { s.Status = TermStopped; s.Color = TextFaint; s.Embedded = false; s.Hwnd = IntPtr.Zero; changed = true; }
        }
        if (changed) RefreshTermList();
        ResizeEmbedded();
    }

    void OnEventFile(string path)
    {
        string ev = "", id = "", payload = "";
        try
        {
            string fn = Path.GetFileNameWithoutExtension(path);
            var parts = fn.Split(new[] { "__" }, StringSplitOptions.None);
            if (parts.Length >= 2) { id = parts[0]; ev = parts[1]; }
            payload = File.ReadAllText(path);
            try { File.Delete(path); } catch { }
        }
        catch { return; }

        TermSession s = null;
        foreach (var t in sessions) if (t.Id == id) { s = t; break; }
        if (s == null) return;

        string actualModel = ModelFromHookPayload(payload);
        if (!string.IsNullOrEmpty(actualModel)) s.Model = actualModel;

        if (s.Status == TermStopped) return;

        if (ev == "ready")
        {
            s.Status = TermReady; s.Color = Green;
        }
        else if (ev == "notify")
        {
            s.Status = TermWaiting; s.Color = Yellow;
            Alert(s.Name, s.Agent + " is waiting for your answer.");
        }
        else if (ev == "stop")
        {
            s.Status = TermWaiting; s.Color = Yellow;
            Alert(s.Name, s.Agent + " finished its turn and is waiting for you.");
        }
        else if (ev == "work")
        {
            s.Status = TermWorking; s.Color = Accent;
        }
        else if (ev == "failure" || ev == "exited")
        {
            s.Status = TermStopped; s.Color = TextFaint;
            Alert(s.Name, s.Agent + " stopped or reached a token/usage limit.");
        }
        RefreshTermList();
    }

    static string ModelFromHookPayload(string payload)
    {
        if (string.IsNullOrWhiteSpace(payload)) return null;
        try
        {
            var match = Regex.Match(payload, "\\\"model\\\"\\s*:\\s*\\\"((?:\\\\.|[^\\\"])*)\\\"");
            if (!match.Success) return null;
            string model = Regex.Unescape(match.Groups[1].Value).Trim();
            return model.Length == 0 || string.Equals(model, "Default", StringComparison.OrdinalIgnoreCase) ? null : model;
        }
        catch { return null; }
    }

    void Alert(string title, string msg)
    {
        try { if (tray != null) tray.ShowBalloonTip(6000, "Hydra — " + title, msg, ToolTipIcon.Info); } catch { }
    }

    // ================= SaaS Builder (Open SaaS) =================
    TextBox SaasBox(string text)
    {
        return new TextBox { Dock = DockStyle.Fill, Margin = new Padding(0, 2, 0, 2), BackColor = Panel2,
            ForeColor = Color.White, BorderStyle = BorderStyle.FixedSingle, Text = text };
    }

    void BuildSaasTab(Control tab)
    {
        // Unified, beginner-friendly one-page journey: Vision -> Deploy -> Subscriptions,
        // stacked top to bottom with numbered stage headers. The whole page scrolls.
        var root = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, BackColor = Color.Transparent,
            AutoScroll = true, Padding = new Padding(22, 16, 22, 18) };
        root.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100f));
        Action<Control, int> row = (c, h) => {
            if (c.Margin == Padding.Empty) c.Margin = new Padding(0);
            c.Dock = DockStyle.Fill;
            root.RowStyles.Add(new RowStyle(SizeType.Absolute, h));
            root.Controls.Add(c);
        };
        Func<object[], int, ComboBox> mkCombo = (items, idx) => {
            var c = new ComboBox { Dock = DockStyle.Fill, Margin = new Padding(0, 2, 8, 2), DropDownStyle = ComboBoxStyle.DropDownList,
                FlatStyle = FlatStyle.Flat, BackColor = Panel2, ForeColor = Color.White };
            c.Items.AddRange(items);
            if (items.Length > 0) c.SelectedIndex = Math.Min(Math.Max(idx, 0), items.Length - 1);
            return c;
        };
        // A caption + control laid out in a table cell.
        Func<string, Control, TableLayoutPanel> cell = (cap, ctrl) => {
            var t = new TableLayoutPanel { BackColor = Color.Transparent, ColumnCount = 1, Margin = new Padding(0) };
            t.RowStyles.Add(new RowStyle(SizeType.Absolute, 18f));
            t.RowStyles.Add(new RowStyle(SizeType.Absolute, 32f));
            var l = RowCap(cap); l.Margin = new Padding(0, 0, 8, 0); t.Controls.Add(l, 0, 0);
            ctrl.Dock = DockStyle.Fill; ctrl.Margin = new Padding(0, 2, 8, 2); t.Controls.Add(ctrl, 0, 1);
            return t;
        };
        // A row of 2 or 3 caption+control cells.
        Func<Control[], TableLayoutPanel> cells = arr => {
            var t = new TableLayoutPanel { BackColor = Color.Transparent, ColumnCount = arr.Length, Margin = new Padding(0) };
            for (int i = 0; i < arr.Length; i++) t.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100f / arr.Length));
            t.RowStyles.Add(new RowStyle(SizeType.Percent, 100f));
            for (int i = 0; i < arr.Length; i++) { arr[i].Dock = DockStyle.Fill; t.Controls.Add(arr[i], i, 0); }
            return t;
        };
        Func<Button[], FlowLayoutPanel> flow = bs => {
            var f = new FlowLayoutPanel { BackColor = Color.Transparent, Margin = new Padding(0), WrapContents = true, Dock = DockStyle.Fill };
            foreach (var b in bs) { b.AutoSize = true; b.Padding = new Padding(8, 4, 8, 4); b.Margin = new Padding(0, 4, 8, 0); f.Controls.Add(b); }
            return f;
        };
        // Big numbered stage header.
        Func<int, string, string, Control> stage = (n, title, sub) => {
            var t = new TableLayoutPanel { BackColor = Color.Transparent, ColumnCount = 2, Margin = new Padding(0, 10, 0, 2) };
            t.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 42f));
            t.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100f));
            t.RowStyles.Add(new RowStyle(SizeType.Percent, 100f));
            var badge = new Label { Text = n.ToString(), ForeColor = Color.Black, BackColor = Accent,
                Font = new Font("Segoe UI", 13f, FontStyle.Bold), TextAlign = ContentAlignment.MiddleCenter, Dock = DockStyle.Fill, Margin = new Padding(0, 3, 10, 3) };
            t.Controls.Add(badge, 0, 0);
            var mid = new TableLayoutPanel { BackColor = Color.Transparent, ColumnCount = 1, Dock = DockStyle.Fill, Margin = new Padding(0) };
            mid.RowStyles.Add(new RowStyle(SizeType.Percent, 55f));
            mid.RowStyles.Add(new RowStyle(SizeType.Percent, 45f));
            mid.Controls.Add(new Label { Text = title, ForeColor = Color.White, Font = new Font("Segoe UI", 12.5f, FontStyle.Bold),
                Dock = DockStyle.Fill, TextAlign = ContentAlignment.BottomLeft }, 0, 0);
            mid.Controls.Add(new Label { Text = sub, ForeColor = TextDim, Font = new Font("Segoe UI", 8.5f),
                Dock = DockStyle.Fill, TextAlign = ContentAlignment.TopLeft }, 0, 1);
            t.Controls.Add(mid, 1, 0);
            return t;
        };
        // Organized, numbered step: badge + title/subtitle + action button on the right.
        Func<int, string, string, Button, Control> step = (n, title, sub, btn) => {
            var t = new TableLayoutPanel { BackColor = Color.Transparent, ColumnCount = 3, Margin = new Padding(0) };
            t.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 30f));
            t.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100f));
            t.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 170f));
            t.RowStyles.Add(new RowStyle(SizeType.Percent, 100f));
            t.Controls.Add(new Label { Text = n > 0 ? n.ToString() : "★", ForeColor = Accent, Font = new Font("Segoe UI", 11f, FontStyle.Bold),
                TextAlign = ContentAlignment.MiddleCenter, Dock = DockStyle.Fill }, 0, 0);
            var mid = new TableLayoutPanel { BackColor = Color.Transparent, ColumnCount = 1, Dock = DockStyle.Fill, Margin = new Padding(0) };
            mid.RowStyles.Add(new RowStyle(SizeType.Percent, 55f));
            mid.RowStyles.Add(new RowStyle(SizeType.Percent, 45f));
            mid.Controls.Add(new Label { Text = title, ForeColor = Color.White, Font = new Font("Segoe UI", 9.75f, FontStyle.Bold),
                Dock = DockStyle.Fill, TextAlign = ContentAlignment.BottomLeft }, 0, 0);
            mid.Controls.Add(new Label { Text = sub, ForeColor = TextDim, Font = new Font("Segoe UI", 8.5f),
                Dock = DockStyle.Fill, TextAlign = ContentAlignment.TopLeft }, 0, 1);
            t.Controls.Add(mid, 1, 0);
            btn.Dock = DockStyle.Fill; btn.Margin = new Padding(6, 7, 0, 7); btn.AutoSize = false;
            t.Controls.Add(btn, 2, 0);
            return t;
        };

        row(PageHeader("Build a SaaS", "From idea to a live, paid product — just follow the three steps below."), 52);

        // ---- shared project bar: name + parent + build model ----
        var proj = new TableLayoutPanel { BackColor = Color.Transparent, ColumnCount = 5, Margin = new Padding(0) };
        proj.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 26f));
        proj.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 36f));
        proj.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 44f));
        proj.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 16f));
        proj.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 22f));
        proj.RowStyles.Add(new RowStyle(SizeType.Absolute, 18f));
        proj.RowStyles.Add(new RowStyle(SizeType.Absolute, 30f));
        var nCap = RowCap("App name (folder-safe)"); nCap.Margin = new Padding(0, 0, 8, 0);
        proj.Controls.Add(nCap, 0, 0);
        proj.Controls.Add(RowCap("Parent folder"), 1, 0);
        proj.Controls.Add(new Label(), 2, 0);
        proj.Controls.Add(RowCap("Builder"), 3, 0);
        proj.Controls.Add(RowCap("Build with model"), 4, 0);
        saasName = SaasBox("my-saas"); saasName.Margin = new Padding(0, 2, 8, 2);
        proj.Controls.Add(saasName, 0, 1);
        saasFolder = SaasBox(HomeDir); saasFolder.Margin = new Padding(0, 2, 8, 2);
        proj.Controls.Add(saasFolder, 1, 1);
        var brB = GhostBtn("…"); brB.Dock = DockStyle.Fill; brB.Margin = new Padding(0, 2, 8, 2);
        brB.Click += (s, e) => { using (var d = new FolderBrowserDialog { ShowNewFolderButton = true }) { if (Directory.Exists(saasFolder.Text)) d.SelectedPath = saasFolder.Text; if (d.ShowDialog() == DialogResult.OK) saasFolder.Text = d.SelectedPath; } };
        proj.Controls.Add(brB, 2, 1);
        saasBuildAgent = mkCombo(new object[] { "Claude", "ChatGPT" }, 0);
        saasBuildAgent.Margin = new Padding(0, 2, 8, 2);
        saasBuildAgent.SelectedIndexChanged += (s, e) => { RefreshSaasBuildModelChoices(); };
        proj.Controls.Add(saasBuildAgent, 3, 1);
        saasBuildModel = mkCombo(ClaudeModelChoices, 0);
        saasBuildModel.Margin = new Padding(0, 2, 0, 2);
        proj.Controls.Add(saasBuildModel, 4, 1);
        row(proj, 52);

        // ---- ⚡ instant mode + live launch checklist ----
        var inst = new TableLayoutPanel { BackColor = Color.Transparent, ColumnCount = 2, Margin = new Padding(0, 6, 0, 0) };
        inst.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100f));
        inst.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 220f));
        inst.RowStyles.Add(new RowStyle(SizeType.Percent, 100f));
        var instMid = new TableLayoutPanel { BackColor = Color.Transparent, ColumnCount = 1, Dock = DockStyle.Fill, Margin = new Padding(0) };
        instMid.RowStyles.Add(new RowStyle(SizeType.Percent, 55f));
        instMid.RowStyles.Add(new RowStyle(SizeType.Percent, 45f));
        instMid.Controls.Add(new Label { Text = "⚡ Instant SaaS", ForeColor = Color.White, Font = new Font("Segoe UI", 11f, FontStyle.Bold), Dock = DockStyle.Fill, TextAlign = ContentAlignment.BottomLeft }, 0, 0);
        instMid.Controls.Add(new Label { Text = "Fill the pitch (or pick a template), then let your builder take it from idea to a live URL in one run.", ForeColor = TextDim, Font = new Font("Segoe UI", 8.5f), Dock = DockStyle.Fill, TextAlign = ContentAlignment.TopLeft }, 0, 1);
        inst.Controls.Add(instMid, 0, 0);
        var instBtn = AccentBtn("⚡ Build it all"); instBtn.Dock = DockStyle.Fill; instBtn.Margin = new Padding(6, 6, 0, 6);
        instBtn.Click += (s, e) => SaasBuildEverything();
        inst.Controls.Add(instBtn, 1, 0);
        row(inst, 52);

        // Live stack preview — exactly what pressing ⚡ will build, before you press it.
        row(RowCap("YOUR STACK — what ⚡ instant build uses (updates live; confirmed again before the run)"), 20);
        saasStackPreview = new Label { Text = "", ForeColor = TextDim, Font = new Font("Consolas", 8.75f), Dock = DockStyle.Fill, TextAlign = ContentAlignment.TopLeft };
        row(saasStackPreview, 172);

        saasProgress = new Label { Text = "", ForeColor = TextFaint, Font = new Font("Segoe UI", 8.75f), Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleLeft };
        row(saasProgress, 22);
        var chkTimer = new System.Windows.Forms.Timer { Interval = 3000 };
        chkTimer.Tick += (s, e) => { UpdateSaasProgress(); RefreshSaasStackPreview(); };
        chkTimer.Start();

        // ================= STAGE 1 — VISION =================
        row(stage(1, "Vision", "Describe your idea, then scaffold the app"), 46);

        saasPreset = mkCombo(new object[] { "Custom",
            // Middle East first — what people here actually need
            "Property rentals (KSA)", "Restaurant QR menu", "Clinic bookings", "Umrah trip organizer",
            "Real-estate CRM", "HR & payroll (KSA)", "WhatsApp storefront", "Quran & tutoring academy",
            "Event ticketing", "Charity & zakat", "Tadawul paper trading (AI)", "AI web scraping service",
            // Global classics
            "AI tool", "Marketplace", "Booking & appointments", "Invoicing & finance", "Courses & learning", "Team dashboard" }, 0);
        saasPreset.SelectedIndexChanged += (s, e) => ApplySaasPreset((saasPreset.SelectedItem ?? "Custom").ToString());
        row(cells(new Control[] { cell("Start from a template (pre-fills pitch, features, tiers)", saasPreset), new Panel { BackColor = Color.Transparent } }), 52);

        row(RowCap("In one line: what does your SaaS do, and for whom?"), 20);
        saasPitch = SaasBox(""); row(saasPitch, 30);

        row(RowCap("Core features / pages (one per line)"), 20);
        saasFeatures = SaasBox(""); saasFeatures.Multiline = true; saasFeatures.ScrollBars = ScrollBars.Vertical;
        row(saasFeatures, 90);

        saasAuth = mkCombo(new object[] { "Email + password", "Google", "GitHub", "Email + Google + GitHub",
            "Firebase Auth (email + Google + Apple)", "Supabase Auth (email + social)", "Clerk (drop-in auth UI)" }, 3);
        saasPay = mkCombo(new object[] { "Lemon Squeezy", "Stripe", "Moyasar (KSA)", "Tap Payments (KSA)", "Polar.sh", "None (add later)" }, 0);
        var payGuide = GhostBtn("Payments guide"); payGuide.Margin = new Padding(0, 2, 0, 2); payGuide.Click += (s, e) => ShowPaymentGuide();
        row(cells(new Control[] { cell("Auth", saasAuth), cell("Payments", saasPay), cell(" ", payGuide) }), 52);

        saasAI = mkCombo(new object[] { "Smart fallback (OpenRouter + Groq + free)", "OpenRouter only (best models)",
            "Groq only (fastest free)", "BYOK (customer brings key)", "None (no AI features)" }, 0);
        row(cells(new Control[] { cell("AI layer", saasAI), new Panel { BackColor = Color.Transparent } }), 52);

        var st1 = GhostBtn("Check / install"); st1.Click += (s, e) => SaasCheckWasp();
        var st2 = GhostBtn("Create app"); st2.Click += (s, e) => SaasCreate();
        var st3 = AccentBtn("Save + build"); st3.Click += (s, e) => SaasBuild();
        row(step(1, "Prerequisites", "Install the Wasp CLI (one-time)", st1), 44);
        row(step(2, "Scaffold", "Create the Open SaaS app folder", st2), 44);
        row(step(3, "Build with builder", "Save your vision, then Claude or ChatGPT builds it", st3), 44);
        var runB = GhostBtn("Run app locally"); runB.Click += (s, e) => SaasRun();
        var docsB = GhostBtn("Open docs"); docsB.Click += (s, e) => { try { Process.Start("https://docs.opensaas.sh"); } catch { } };
        row(flow(new Button[] { runB, docsB }), 44);

        // ================= STAGE 2 — DEPLOY =================
        row(stage(2, "Deploy", "Put it online via GitHub + your cloud of choice"), 46);

        saasTarget = mkCombo(new object[] { "Vercel", "Firebase Hosting", "Cloud Run" }, 0);
        saasBackend = mkCombo(new object[] { "None (static site)", "Firebase Functions + Firestore", "Cloud Run API (container)", "Vercel Serverless (/api)" }, 0);
        row(cells(new Control[] { cell("Deploy target", saasTarget), cell("Backend", saasBackend) }), 52);

        saasRegion = mkCombo(new object[] { "us-central1", "us-east1", "europe-west1", "me-central2", "asia-south1" }, 0);
        saasServiceName = SaasBox("api");
        saasGcpProject = SaasBox("");
        row(cells(new Control[] { cell("Region (Cloud Run)", saasRegion), cell("Service name", saasServiceName), cell("Project id (GCP/Firebase)", saasGcpProject) }), 52);

        saasPublicDir = SaasBox("dist");
        saasRepoVis = mkCombo(new object[] { "Private", "Public" }, 0);
        row(cells(new Control[] { cell("Public dir (Firebase)", saasPublicDir), cell("GitHub repository", saasRepoVis) }), 52);

        var ghNote = new Label { Text = "GitHub is the core home for your code — push a private repo, then auto-deploy every change to your host.",
            ForeColor = TextFaint, Font = new Font("Segoe UI", 8.5f), Dock = DockStyle.Fill };
        row(ghNote, 26);

        // Guided 3-step deploy (replaces the old wall of buttons).
        row(RowCap("GO LIVE — 3 STEPS  ·  new to deploying? do these in order"), 22);
        var dConn = GhostBtn("Connect"); dConn.Click += (s, e) => SaasConnectHost();
        var dPush = GhostBtn("Create repo + push"); dPush.Click += (s, e) => SaasPushToGitHub();
        var dNow = AccentBtn("Deploy now"); dNow.Click += (s, e) => SaasDeployNow();
        row(step(1, "Connect your host", "Install the CLI and sign in", dConn), 44);
        row(step(2, "Push to GitHub", "Create your repo — code home & deploy source", dPush), 44);
        row(step(3, "Go live", "Publish and get your live URL (config written for you)", dNow), 44);

        var dClaude = OkBtn("Let builder deploy it"); dClaude.Click += (s, e) => SaasBuildDeployWithClaude();
        row(step(0, "Rather not do it yourself?", "Claude or ChatGPT sets up config, backend, CI/CD and deploys — end to end", dClaude), 44);

        var dCi = GhostBtn("Auto-deploy on push"); dCi.Click += (s, e) => SaasAddGitHubActions();
        var dScaf = GhostBtn("Config files"); dScaf.Click += (s, e) => SaasScaffoldDeploy();
        var dGuide = GhostBtn("Guide"); dGuide.Click += (s, e) => SaasOpenDeployGuide();
        var dChk = GhostBtn("Check tools"); dChk.Click += (s, e) => SaasCheckDeployTools();
        row(flow(new Button[] { dCi, dScaf, dGuide, dChk }), 44);

        // ================= STAGE 3 — SUBSCRIPTIONS =================
        row(stage(3, "Subscriptions", "Charge users and email your subscribers"), 46);

        saasSubProvider = mkCombo(new object[] { "Lemon Squeezy", "Stripe", "Moyasar (KSA)", "Tap Payments (KSA)" }, 0);
        saasTrial = SaasBox("14");
        row(cells(new Control[] { cell("Billing provider", saasSubProvider), cell("Free trial (days)", saasTrial) }), 52);

        row(RowCap("Plans / tiers (one per line)"), 20);
        saasTiers = SaasBox("Free — 0 SAR\r\nPro — 69 SAR/mo\r\nTeam — 199 SAR/mo");
        saasTiers.Multiline = true; saasTiers.ScrollBars = ScrollBars.Vertical;
        row(saasTiers, 72);

        saasEmailProvider = mkCombo(new object[] { "Resend", "Postmark", "SendGrid" }, 0);
        saasFromEmail = SaasBox("billing@yourdomain.com");
        row(cells(new Control[] { cell("Email provider", saasEmailProvider), cell("Send from", saasFromEmail) }), 52);

        var subNote = new Label { Text = "Subscribers get transactional email (receipts, dunning) + broadcasts, with SPF/DKIM/DMARC and one-click unsubscribe.",
            ForeColor = TextFaint, Font = new Font("Segoe UI", 8.5f), Dock = DockStyle.Fill };
        row(subNote, 30);

        var sScaf = GhostBtn("Scaffold specs"); sScaf.Click += (s, e) => SaasScaffoldSubscriptions();
        var sBuild = AccentBtn("Build with builder"); sBuild.Click += (s, e) => SaasBuildSubsWithClaude();
        var sDocs = GhostBtn("Billing docs"); sDocs.Click += (s, e) => SaasOpenBillingDocs();
        row(flow(new Button[] { sScaf, sBuild, sDocs }), 44);

        saasStatus = new TextBox { Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical, WordWrap = true,
            BackColor = Color.FromArgb(18, 18, 20), ForeColor = TextDim, BorderStyle = BorderStyle.FixedSingle, Font = new Font("Consolas", 9.5f),
            Margin = new Padding(0, 8, 0, 0), Dock = DockStyle.Fill,
            Text = "From idea to a live, paid product — follow the three steps above." };
        row(saasStatus, 150);

        // Help bubbles — hover any field for a detailed explanation (the Windows analog of the "?" popovers).
        var tip = new ToolTip { AutoPopDelay = 30000, InitialDelay = 300, ReshowDelay = 100, ShowAlways = true, IsBalloon = true, ToolTipTitle = "What is this?" };
        tip.SetToolTip(saasName, "The folder + repo name for your app. Lowercase, no spaces (e.g. my-saas).");
        tip.SetToolTip(saasBuildModel, "Which model builds the SaaS. ChatGPT uses Codex and includes gpt-5.6-sol, gpt-5.6-terra, and gpt-5.6-luna; Claude uses the Claude model list.");
        tip.SetToolTip(saasPitch, "Your one-line elevator pitch. Claude uses it to understand the product's purpose and target user — it shapes every screen and feature. Be specific about WHO it's for.");
        tip.SetToolTip(saasFeatures, "The main pages/capabilities, one per line (e.g. Dashboard, Invoice editor, Client list). Claude turns each into real routes, UI, and database models.");
        tip.SetToolTip(saasAuth, "How users sign in. Email + password is simplest; adding Google/GitHub gives one-click login (built into Open SaaS). Integrated platforms go further: Firebase Auth = Google's hosted sign-in (email + Google + Apple, free tier); Supabase Auth = same idea on Postgres; Clerk = drop-in sign-in components with almost no code. Claude wires your pick, including syncing users into your database.");
        tip.SetToolTip(saasPay, "Which processor charges your customers. Lemon Squeezy is the default global merchant-of-record path. Tap & Moyasar support mada, Apple Pay and STC Pay for Saudi customers. Claude gets a verified integration spec for your choice.");
        tip.SetToolTip(saasTarget, "Where your site goes live. Vercel = fastest for React/Next.js. Firebase = Hosting + Firestore + Auth together. Cloud Run = a container for any language / long-running backend.");
        tip.SetToolTip(saasBackend, "What powers your server logic. None = static site. Firebase Functions + Firestore = serverless API + DB. Cloud Run API = your container. Vercel Serverless = functions in /api.");
        tip.SetToolTip(saasRegion, "The datacenter that runs your Cloud Run service. Pick one near your users (e.g. me-central2 for the Middle East).");
        tip.SetToolTip(saasServiceName, "The Cloud Run service name — appears in its URL. Lowercase, e.g. api.");
        tip.SetToolTip(saasGcpProject, "Your Google Cloud / Firebase project id (from the console). Deploys and CI/CD target this project.");
        tip.SetToolTip(saasPublicDir, "The folder your build produces and Firebase serves. Vite -> dist, Create React App -> build.");
        tip.SetToolTip(saasRepoVis, "Your code lives in a GitHub repo — the single source of truth. Private keeps it hidden. Every push can then auto-deploy via GitHub Actions.");
        tip.SetToolTip(saasSubProvider, "Who charges subscribers on a recurring basis. Lemon Squeezy and Stripe include hosted subscription billing and customer management. Tap & Moyasar handle Saudi recurring payments with your own scheduled charging flow.");
        tip.SetToolTip(saasTrial, "How many days new users get free before the first charge. 0 = no trial.");
        tip.SetToolTip(saasTiers, "Your pricing tiers, one per line as Name — price. Your builder creates the plan picker, checkout, and feature-gating from these.");
        tip.SetToolTip(saasEmailProvider, "Who sends your emails. Resend = modern & easy. Postmark = best deliverability for receipts. SendGrid = mature with campaigns. Used for receipts, dunning, and newsletters.");
        tip.SetToolTip(saasFromEmail, "The from address subscribers see. Use a domain you control — add SPF/DKIM/DMARC DNS records so email lands in the inbox.");
        tip.SetToolTip(saasPreset, "Pre-fills the pitch, features, and pricing tiers for a common SaaS type — Middle-East-first ideas at the top. Pick Custom to write everything yourself. Choosing a template overwrites those three fields.");
        tip.SetToolTip(saasStackPreview, "This is the exact stack the ⚡ instant build uses — it updates live as you change the options below. Every build starts from the Open SaaS template (github.com/wasp-lang/open-saas): Wasp + React + Node.js + Prisma + PostgreSQL, whatever the use case. You'll also confirm this summary in a dialog before anything runs.");
        tip.SetToolTip(saasAI, "The brain behind your AI features — our own integrated router, not a third-party gateway. It calls providers in a best-to-cheapest priority order and falls back automatically when one is rate-limited. Smart fallback serves free users on commercial-free models (Groq, OpenRouter :free, Gemini) at $0 and unlocks frontier models (GPT-4o, Gemini 2.5 Pro, DeepSeek R1) for paid tiers. OpenRouter only = one key, 300+ models. Groq only = fastest free tokens. BYOK = each customer brings their own key, so AI costs you nothing. Every provider allows commercial use within its free limits. Your builder drops a ready router (src/server/ai/router.ts) into the app.");

        // ---- restore the saved form, then autosave any change (via the checklist timer) ----
        LoadSaasForm();
        foreach (Control c in new Control[] { saasName, saasFolder, saasPitch, saasFeatures, saasGcpProject, saasServiceName, saasPublicDir, saasTiers, saasTrial, saasFromEmail })
            c.TextChanged += (s, e) => { saasDirty = true; RefreshSaasStackPreview(); };
        foreach (ComboBox c in new[] { saasAuth, saasPay, saasBuildAgent, saasBuildModel, saasTarget, saasBackend, saasRegion, saasRepoVis, saasSubProvider, saasEmailProvider, saasPreset, saasAI })
            c.SelectedIndexChanged += (s, e) => { saasDirty = true; RefreshSaasStackPreview(); };
        UpdateSaasProgress();
        RefreshSaasStackPreview();

        tab.Controls.Add(root);
    }

    // ---- deploy helpers ----
    // The folder deploy/billing actions operate on. NEVER falls back to the home folder —
    // pushing it to GitHub or writing a Dockerfile into it would be catastrophic. The parent
    // is only used when it clearly IS a project itself (user pointed us at existing code).
    string SaasDeployDir()
    {
        string app = SaasAppDir();
        if (Directory.Exists(app)) return app;
        string p = (saasFolder.Text ?? "").Trim().TrimEnd('\\', '/');
        string home = HomeDir.TrimEnd('\\', '/');
        if (p.Length == 0 || !Directory.Exists(p)) return "";
        bool looksLikeProject = File.Exists(Path.Combine(p, "package.json")) || File.Exists(Path.Combine(p, "main.wasp"))
            || File.Exists(Path.Combine(p, "index.html")) || Directory.Exists(Path.Combine(p, ".git"));
        if (!string.Equals(p, home, StringComparison.OrdinalIgnoreCase) && looksLikeProject) return p;
        return "";
    }
    bool SaasDeployDirValid()
    {
        if (SaasDeployDir().Length == 0)
        {
            MessageBox.Show("Create your app first (Stage 1), or point 'Parent folder' at an existing project (a folder with package.json / .git). To protect you, these actions never run on your home folder.", "Hydra");
            return false;
        }
        return true;
    }
    // Run a plain shell command in a console window rooted at dir.
    void SaasRunTerm(string command, string dir, string note)
    {
        if (!string.IsNullOrEmpty(note)) SaasLog(note);
        try
        {
            var psi = new ProcessStartInfo("cmd.exe", "/k cd /d \"" + dir + "\" && " + command) { UseShellExecute = true };
            Process.Start(psi);
        }
        catch (Exception ex) { SaasLog("Failed: " + ex.Message); }
    }
    string SaasBuilderName()
    {
        return (saasBuildAgent != null && saasBuildAgent.SelectedItem != null) ? saasBuildAgent.SelectedItem.ToString() : "Claude";
    }
    // Launch the selected SaaS builder in an embedded workspace terminal with the chosen model.
    void SaasLaunchBuilder(string dir, string prompt)
    {
        string savedExtra = extraBox.Text, savedModel = modelCombo.Text;
        object savedAgent = agentCombo != null ? agentCombo.SelectedItem : null;
        try
        {
            pathBox.Text = dir;
            string builder = SaasBuilderName();
            if (agentCombo != null) agentCombo.SelectedItem = builder == "ChatGPT" ? "Codex" : "Claude";
            extraBox.Text = "\"" + prompt.Replace("\"", "'") + "\"";
            string bm = saasBuildModel != null ? (saasBuildModel.Text ?? "").Trim() : "";
            if (bm.Length > 0) modelCombo.Text = bm;
            NewTerminal(dir);
        }
        finally
        {
            if (agentCombo != null && savedAgent != null) agentCombo.SelectedItem = savedAgent;
            extraBox.Text = savedExtra;
            modelCombo.Text = savedModel;
        }
    }

    void SaasTargetTool(out string exe, out string install, out string login)
    {
        string t = (saasTarget.SelectedItem ?? "Vercel").ToString();
        if (t == "Firebase Hosting") { exe = "firebase"; install = "npm install -g firebase-tools"; login = "firebase login"; }
        else if (t == "Cloud Run") { exe = "gcloud"; install = OnPath("choco") ? "choco install gcloudsdk -y" : "echo Install the Google Cloud SDK: https://cloud.google.com/sdk/docs/install  (then run: gcloud init)"; login = "gcloud auth login"; }
        else { exe = "vercel"; install = "npm install -g vercel"; login = "vercel login"; }
    }

    void SaasCheckDeployTools()
    {
        Func<string, string> mk = e => OnPath(e) || OnPath(e + ".exe") || OnPath(e + ".cmd") ? "OK" : "—";
        SaasLog("Tools:  git " + mk("git") + "   gh " + mk("gh") + "   node " + mk("node") + "   npm " + mk("npm") + "   firebase " + mk("firebase") + "   vercel " + mk("vercel") + "   gcloud " + mk("gcloud") + "   docker " + mk("docker"));
        string exe, install, login; SaasTargetTool(out exe, out install, out login);
        SaasLog(OnPath(exe) || OnPath(exe + ".cmd") ? (exe + " is ready for " + saasTarget.SelectedItem + ".") : (exe + " missing — click Install CLI."));
    }
    void SaasInstallCLI()
    {
        string exe, install, login; SaasTargetTool(out exe, out install, out login);
        if (OnPath(exe) || OnPath(exe + ".cmd")) { SaasLog(exe + " already installed."); return; }
        SaasRunTerm(install, HomeDir, "Installing the " + saasTarget.SelectedItem + " CLI…");
    }
    void SaasDeployLogin()
    {
        if (!SaasDeployDirValid()) return;
        string exe, install, login; SaasTargetTool(out exe, out install, out login);
        string cmd = login;
        string proj = (saasGcpProject.Text ?? "").Trim();
        if ((saasTarget.SelectedItem ?? "").ToString() == "Cloud Run" && proj.Length > 0) cmd += " && gcloud config set project " + proj;
        SaasRunTerm(cmd, SaasDeployDir(), "Sign in to " + saasTarget.SelectedItem + "… a browser may open.");
    }

    void SaasScaffoldDeploy()
    {
        if (!SaasDeployDirValid()) return;
        string dir = SaasDeployDir();
        string t = (saasTarget.SelectedItem ?? "Vercel").ToString();
        var wrote = new List<string>();
        try
        {
            if (t == "Firebase Hosting")
            {
                File.WriteAllText(Path.Combine(dir, "firebase.json"), SaasFirebaseJson()); wrote.Add("firebase.json");
                if ((saasGcpProject.Text ?? "").Trim().Length > 0) { File.WriteAllText(Path.Combine(dir, ".firebaserc"), SaasFirebaseRc()); wrote.Add(".firebaserc"); }
            }
            else if (t == "Cloud Run")
            {
                File.WriteAllText(Path.Combine(dir, "Dockerfile"), SaasDockerfile()); wrote.Add("Dockerfile");
                File.WriteAllText(Path.Combine(dir, ".dockerignore"), "node_modules\nnpm-debug.log\n.git\n.env*\n"); wrote.Add(".dockerignore");
            }
            else { File.WriteAllText(Path.Combine(dir, "vercel.json"), SaasVercelJson()); wrote.Add("vercel.json"); }
            File.WriteAllText(Path.Combine(dir, "DEPLOY.md"), SaasDeploySpec()); wrote.Add("DEPLOY.md");
            SaasLog("Wrote " + string.Join(", ", wrote.ToArray()) + " into " + dir);
            SaasLog("Review the config, then Deploy now. Or Build with " + SaasBuilderName() + " to wire the backend + config end-to-end.");
        }
        catch (Exception ex) { SaasLog("Scaffold failed: " + ex.Message); }
    }

    // One beginner-friendly action: install the host CLI if missing, then sign in
    // (and select the project for Cloud Run) — all in a single console.
    void SaasConnectHost()
    {
        if (!SaasDeployDirValid()) return;
        string exe, install, login; SaasTargetTool(out exe, out install, out login);
        string installStep = (OnPath(exe) || OnPath(exe + ".cmd")) ? "echo " + exe + " already installed." : install;
        string cmd = installStep + " && " + login;
        string proj = (saasGcpProject.Text ?? "").Trim();
        if ((saasTarget.SelectedItem ?? "").ToString() == "Cloud Run" && proj.Length > 0) cmd += " && gcloud config set project " + proj;
        SaasRunTerm(cmd, SaasDeployDir(), "Connecting to " + saasTarget.SelectedItem + " — installing the CLI (if needed) and signing in. A browser may open.");
        SaasLog("Connecting to " + saasTarget.SelectedItem + ". Finish any sign-in in the console, then come back for step 2.");
    }

    // Write the target's config files if missing so Deploy now just works.
    void SaasEnsureDeployConfig()
    {
        string dir = SaasDeployDir();
        string t = (saasTarget.SelectedItem ?? "Vercel").ToString();
        try
        {
            if (t == "Firebase Hosting")
            {
                if (!File.Exists(Path.Combine(dir, "firebase.json"))) { File.WriteAllText(Path.Combine(dir, "firebase.json"), SaasFirebaseJson()); SaasLog("Wrote firebase.json"); }
                if ((saasGcpProject.Text ?? "").Trim().Length > 0 && !File.Exists(Path.Combine(dir, ".firebaserc"))) { File.WriteAllText(Path.Combine(dir, ".firebaserc"), SaasFirebaseRc()); SaasLog("Wrote .firebaserc"); }
            }
            else if (t == "Cloud Run")
            {
                if (!File.Exists(Path.Combine(dir, "Dockerfile"))) { File.WriteAllText(Path.Combine(dir, "Dockerfile"), SaasDockerfile()); SaasLog("Wrote Dockerfile"); }
                if (!File.Exists(Path.Combine(dir, ".dockerignore"))) File.WriteAllText(Path.Combine(dir, ".dockerignore"), "node_modules\nnpm-debug.log\n.git\n.env*\n");
            }
            else { if (!File.Exists(Path.Combine(dir, "vercel.json"))) { File.WriteAllText(Path.Combine(dir, "vercel.json"), SaasVercelJson()); SaasLog("Wrote vercel.json"); } }
        }
        catch { }
    }

    void SaasDeployNow()
    {
        if (!SaasDeployDirValid()) return;
        string exe, install, login; SaasTargetTool(out exe, out install, out login);
        if (!(OnPath(exe) || OnPath(exe + ".cmd"))) { MessageBox.Show("Not connected — run step 1 (Connect your host) first; it installs the " + exe + " CLI and signs you in.", "Hydra"); return; }
        SaasEnsureDeployConfig();
        string dir = SaasDeployDir();
        string t = (saasTarget.SelectedItem ?? "Vercel").ToString();
        string cmd;
        if (t == "Firebase Hosting") cmd = "firebase deploy";
        else if (t == "Cloud Run")
        {
            string proj = (saasGcpProject.Text ?? "").Trim();
            string svc = (saasServiceName.Text ?? "").Trim(); if (svc.Length == 0) svc = "api";
            cmd = "gcloud run deploy " + svc + " --source . --region " + (saasRegion.SelectedItem ?? "us-central1") + " --allow-unauthenticated" + (proj.Length > 0 ? " --project " + proj : "");
        }
        else cmd = "vercel --prod";
        SaasRunTerm(cmd, dir, "Deploying to " + saasTarget.SelectedItem + "… watch for the live URL.");
    }

    void SaasBuildDeployWithClaude()
    {
        if (!SaasDeployDirValid()) return;
        string dir = SaasDeployDir();
        try { File.WriteAllText(Path.Combine(dir, "DEPLOY.md"), SaasDeploySpec()); } catch (Exception ex) { SaasLog("Could not write DEPLOY.md: " + ex.Message); return; }
        string prompt = "Read DEPLOY.md in this folder and get this project deployed to " + saasTarget.SelectedItem + " with the specified backend. This is an Open SaaS (Wasp) app (" + SaasTemplateRepo + ") — use `wasp build` outputs (static client + server Dockerfile) rather than assuming a plain SPA. Set up the config, wire the backend/database, handle env vars/secrets safely, then run the deploy and report the live URL. Confirm the plan before any paid or destructive step." + SaasSkillsHint();
        SaasLaunchBuilder(dir, prompt);
        SaasLog("Wrote DEPLOY.md and opened " + SaasBuilderName() + " in the Workspace to deploy it.");
    }

    void SaasOpenDeployGuide()
    {
        string dir = Directory.Exists(SaasDeployDir()) ? SaasDeployDir() : StateDir;
        string path = Path.Combine(dir, "CLOUD-DEPLOYMENT.md");
        try { File.WriteAllText(path, SaasCloudGuide()); Process.Start(path); } catch (Exception ex) { SaasLog("Could not open guide: " + ex.Message); }
    }

    // ---- GitHub: private repo + Actions CI/CD (the core deploy location) ----
    void SaasEnsureGitignore()
    {
        string p = Path.Combine(SaasDeployDir(), ".gitignore");
        if (File.Exists(p)) return;
        try { File.WriteAllText(p, "node_modules\n.env\n.env.*\n!.env.example\n!.env.subscriptions.example\n!.env.analytics.example\n!.env.ai.example\ndist\nbuild\n.next\n.DS_Store\n.firebase\n.vercel\n"); SaasLog("Wrote .gitignore (keeps secrets + build output out of git)."); } catch { }
    }
    void SaasPushToGitHub()
    {
        if (!SaasDeployDirValid()) return;
        string dir = SaasDeployDir();
        string n = (saasName.Text ?? "").Trim();
        if (!(OnPath("gh") || OnPath("gh.exe")))
        {
            string install = OnPath("winget") ? "winget install --id GitHub.cli -e && gh auth login" : "echo Install the GitHub CLI: https://cli.github.com  then run: gh auth login";
            SaasRunTerm(install, dir, "Installing the GitHub CLI (gh)…");
            SaasLog("gh not found — installing it. After gh auth login, click Create repo + push again.");
            return;
        }
        SaasEnsureGitignore();
        string vis = (saasRepoVis.SelectedItem ?? "Private").ToString() == "Public" ? "--public" : "--private";
        string cmd = "git rev-parse --git-dir >nul 2>&1 || git init -b main && git add -A && (git commit -m \"Initial commit\" || echo (nothing new to commit)) && (gh repo view >nul 2>&1 && git push -u origin HEAD || gh repo create \"" + n + "\" " + vis + " --source . --remote origin --push)";
        SaasRunTerm(cmd, dir, "Creating a " + vis.Substring(2) + " GitHub repo and pushing the project…");
        SaasLog("Pushing to a " + vis.Substring(2) + " GitHub repo. If it asks you to authenticate, run gh auth login and retry.");
    }
    void SaasAddGitHubActions()
    {
        if (!SaasDeployDirValid()) return;
        string dir = SaasDeployDir();
        string file, doc; string[] secrets;
        string content = SaasGhWorkflow(out file, out secrets, out doc);
        try
        {
            string wfDir = Path.Combine(dir, ".github", "workflows");
            Directory.CreateDirectory(wfDir);
            File.WriteAllText(Path.Combine(wfDir, file), content);
            File.WriteAllText(Path.Combine(dir, "GITHUB-ACTIONS.md"), doc);
            SaasLog("Wrote .github/workflows/" + file + " + GITHUB-ACTIONS.md");
            SaasLog("Add these repo secrets (GitHub → Settings → Secrets → Actions, or gh secret set): " + string.Join(", ", secrets));
            SaasLog("Then every push to main auto-deploys to " + saasTarget.SelectedItem + ".");
        }
        catch (Exception ex) { SaasLog("Could not write workflow: " + ex.Message); }
    }
    string SaasGhWorkflow(out string file, out string[] secrets, out string doc)
    {
        string t = (saasTarget.SelectedItem ?? "Vercel").ToString();
        if (t == "Firebase Hosting")
        {
            string proj = (saasGcpProject.Text ?? "").Trim(); if (proj.Length == 0) proj = "your-project-id";
            file = "deploy-firebase.yml"; secrets = new[] { "FIREBASE_SERVICE_ACCOUNT" };
            doc = "# GitHub Actions → Firebase Hosting\n\nEvery push to main builds and deploys to Firebase Hosting.\n\n## Required secret\n- FIREBASE_SERVICE_ACCOUNT — a service-account JSON with the Firebase Hosting Admin role.\n\nFastest way (auto-adds the secret to your repo):\n```\nfirebase init hosting:github\n```\nGITHUB_TOKEN is provided automatically by Actions.\n\n## No-service-account alternative (proven simpler)\nIf the user already has a CI token (`firebase login:ci`), skip the service account: set a FIREBASE_TOKEN repo secret and replace the deploy step with `npx firebase-tools deploy --only hosting --non-interactive --token \"$FIREBASE_TOKEN\"` (project id comes from .firebaserc).\n\n## Wasp projects (Open SaaS) — pitfalls that WILL fail the first run\n- Pin the CLI: `npm install -g @wasp.sh/wasp-cli@<same version as local>` — unpinned installs drift.\n- Wasp 0.24+ requires Node 24: setup-node with node-version: 24.\n- Build order: `wasp install && wasp build` in app/, then `npx vite build` in app/ (client output lands in app/.wasp/out/web-app/build; copy it to the Hosting public dir).\n- The client build hard-fails without REACT_APP_API_URL in env — set it as a repo secret.\n";
            return "name: Deploy to Firebase Hosting\non:\n  push:\n    branches: [main]\njobs:\n  build_and_deploy:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@v4\n      - uses: actions/setup-node@v4\n        with:\n          node-version: 20\n      - run: npm ci\n      - run: npm run build --if-present\n      - uses: FirebaseExtended/action-hosting-deploy@v0\n        with:\n          repoToken: ${{ secrets.GITHUB_TOKEN }}\n          firebaseServiceAccount: ${{ secrets.FIREBASE_SERVICE_ACCOUNT }}\n          channelId: live\n          projectId: " + proj + "\n";
        }
        if (t == "Cloud Run")
        {
            string proj = (saasGcpProject.Text ?? "").Trim(); if (proj.Length == 0) proj = "your-project-id";
            string svc = (saasServiceName.Text ?? "").Trim(); if (svc.Length == 0) svc = "api";
            file = "deploy-cloudrun.yml"; secrets = new[] { "GCP_SA_KEY" };
            doc = "# GitHub Actions → Cloud Run\n\nEvery push to main builds from source and deploys to Cloud Run.\n\n## Required secret\n- GCP_SA_KEY — service-account JSON with Cloud Run Admin, Cloud Build Editor, Service Account User, Storage Admin.\n\n```\ngcloud iam service-accounts keys create key.json --iam-account=deployer@" + proj + ".iam.gserviceaccount.com\ngh secret set GCP_SA_KEY < key.json   (then delete key.json)\n```\nEnsure the app listens on $PORT (8080) on 0.0.0.0.\n";
            return "name: Deploy to Cloud Run\non:\n  push:\n    branches: [main]\njobs:\n  deploy:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@v4\n      - uses: google-github-actions/auth@v2\n        with:\n          credentials_json: ${{ secrets.GCP_SA_KEY }}\n      - uses: google-github-actions/setup-gcloud@v2\n      - run: gcloud run deploy " + svc + " --source . --region " + (saasRegion.SelectedItem ?? "us-central1") + " --project " + proj + " --allow-unauthenticated\n";
        }
        file = "deploy-vercel.yml"; secrets = new[] { "VERCEL_TOKEN", "VERCEL_ORG_ID", "VERCEL_PROJECT_ID" };
        doc = "# GitHub Actions → Vercel\n\nEvery push to main builds and promotes to Vercel production.\n\n## Required secrets\n- VERCEL_TOKEN — https://vercel.com/account/tokens\n- VERCEL_ORG_ID and VERCEL_PROJECT_ID — run `vercel link`, then read them from .vercel/project.json.\n\n```\nvercel link\ngh secret set VERCEL_TOKEN\ngh secret set VERCEL_ORG_ID --body (jq -r .orgId .vercel/project.json)\ngh secret set VERCEL_PROJECT_ID --body (jq -r .projectId .vercel/project.json)\n```\n";
        return "name: Deploy to Vercel\non:\n  push:\n    branches: [main]\nenv:\n  VERCEL_ORG_ID: ${{ secrets.VERCEL_ORG_ID }}\n  VERCEL_PROJECT_ID: ${{ secrets.VERCEL_PROJECT_ID }}\njobs:\n  deploy:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@v4\n      - uses: actions/setup-node@v4\n        with:\n          node-version: 20\n      - run: npm install -g vercel\n      - run: vercel pull --yes --environment=production --token=${{ secrets.VERCEL_TOKEN }}\n      - run: vercel build --prod --token=${{ secrets.VERCEL_TOKEN }}\n      - run: vercel deploy --prebuilt --prod --token=${{ secrets.VERCEL_TOKEN }}\n";
    }

    // ---- deploy config + spec generators ----
    string SaasFirebaseJson()
    {
        bool fn = (saasBackend.SelectedItem ?? "").ToString().StartsWith("Firebase");
        string pub = (saasPublicDir.Text ?? "dist").Trim(); if (pub.Length == 0) pub = "dist";
        var sb = new StringBuilder();
        sb.Append("{\n  \"hosting\": {\n    \"public\": \"" + pub + "\",\n    \"ignore\": [\"firebase.json\", \"**/.*\", \"**/node_modules/**\"],\n    \"rewrites\": [\n");
        if (fn) sb.Append("      { \"source\": \"/api/**\", \"function\": \"api\" },\n");
        sb.Append("      { \"source\": \"**\", \"destination\": \"/index.html\" }\n    ]\n  }");
        if (fn) sb.Append(",\n  \"functions\": { \"source\": \"functions\" }");
        sb.Append("\n}\n");
        return sb.ToString();
    }
    string SaasFirebaseRc() { return "{ \"projects\": { \"default\": \"" + (saasGcpProject.Text ?? "").Trim() + "\" } }\n"; }
    string SaasVercelJson() { return "{\n  \"$schema\": \"https://openapi.vercel.sh/vercel.json\",\n  \"rewrites\": [{ \"source\": \"/(.*)\", \"destination\": \"/\" }]\n}\n"; }
    string SaasDockerfile()
    {
        return "# Cloud Run container — MUST listen on $PORT (default 8080) on 0.0.0.0.\nFROM node:20-slim\nWORKDIR /app\nCOPY package*.json ./\nRUN npm ci --omit=dev\nCOPY . .\nENV NODE_ENV=production\nEXPOSE 8080\n# Ensure your server uses: const port = process.env.PORT || 8080; app.listen(port, \"0.0.0.0\")\nCMD [\"node\", \"server.js\"]\n";
    }
    string SaasDeploySpec()
    {
        string t = (saasTarget.SelectedItem ?? "Vercel").ToString();
        var sb = new StringBuilder();
        sb.AppendLine("# Deployment spec — " + (saasName.Text ?? "").Trim());
        sb.AppendLine();
        sb.AppendLine("- Base app: **Open SaaS (Wasp)** — " + SaasTemplateRepo + " (mandatory template for every use case)");
        sb.AppendLine("- Target: **" + t + "**");
        sb.AppendLine("- Backend: **" + (saasBackend.SelectedItem ?? "") + "**");
        if (t == "Cloud Run") { sb.AppendLine("- Region: " + saasRegion.SelectedItem); sb.AppendLine("- Service: " + (saasServiceName.Text ?? "").Trim()); if ((saasGcpProject.Text ?? "").Trim().Length > 0) sb.AppendLine("- GCP project: " + (saasGcpProject.Text ?? "").Trim()); }
        if (t == "Firebase Hosting") sb.AppendLine("- Public dir: " + (saasPublicDir.Text ?? "dist").Trim());
        sb.AppendLine();
        sb.AppendLine("> Open SaaS note: `wasp build` outputs the client at `.wasp/build/web-app` (run `npm install && npm run build` there → static files for the hosting target) and a server with a Dockerfile at `.wasp/build` (deploy to a container host — Cloud Run works). The server needs a PostgreSQL `DATABASE_URL` plus `WASP_WEB_CLIENT_URL` / `WASP_SERVER_URL` env vars.");
        sb.AppendLine();
        sb.AppendLine("## What to do");
        if (t == "Firebase Hosting")
            sb.AppendLine("1. `firebase login`; ensure the project in .firebaserc exists.\n2. Build the frontend so the public dir is produced.\n3. If backend is Functions: `firebase init functions`, implement the API, keep the /api/** rewrite ABOVE the SPA catch-all.\n4. If Firestore: `firebase init firestore`, write default-deny rules, deploy rules.\n5. `firebase deploy` and report the Hosting URL. Smoke-test it.");
        else if (t == "Cloud Run")
            sb.AppendLine("1. Ensure the server listens on process.env.PORT on 0.0.0.0 (default 8080).\n2. `gcloud auth login` and set the project; enable run.googleapis.com + cloudbuild.googleapis.com.\n3. Secrets via Secret Manager; env via --set-env-vars. DB via Cloud SQL or a serverless DATABASE_URL.\n4. `gcloud run deploy " + ((saasServiceName.Text ?? "api").Trim()) + " --source . --region " + saasRegion.SelectedItem + " --allow-unauthenticated`. Report the URL and smoke-test it.");
        else
            sb.AppendLine("1. `vercel login`; run `vercel` (preview) then `vercel --prod`.\n2. Framework auto-detected; add vercel.json only for overrides.\n3. Backend: serverless endpoints in /api. Env: `vercel env add NAME production` (client vars need NEXT_PUBLIC_/VITE_).\n4. Connect a managed DB (Neon/Supabase/Upstash) via DATABASE_URL. Report the URL and smoke-test it.");
        sb.AppendLine();
        sb.AppendLine("## GitHub is the core deploy location");
        sb.AppendLine("- Host the project as a **" + (saasRepoVis.SelectedItem ?? "Private").ToString().ToLower() + "** GitHub repository (the app can create + push it).");
        sb.AppendLine("- CI/CD: a GitHub Actions workflow deploys every push to main to " + t + ". See GITHUB-ACTIONS.md for the exact secrets.");
        sb.AppendLine();
        sb.AppendLine("See CLOUD-DEPLOYMENT.md and the bundled `cloud-deployment` skill for full details. Never commit secrets; add .env* to .gitignore.");
        return sb.ToString();
    }
    string SaasCloudGuide()
    {
        string svc = (saasServiceName.Text ?? "api").Trim(); string reg = (saasRegion.SelectedItem ?? "us-central1").ToString(); string pub = (saasPublicDir.Text ?? "dist").Trim();
        return "# Cloud Deployment — quick field guide\n\n## Pick a target\n- Static/SPA → Firebase Hosting or Vercel\n- Next.js/SSR → Vercel (zero-config)\n- Container/any language/long-running → Cloud Run\n- Firestore + Auth → Firebase\n\n## Vercel\n- `npm i -g vercel` → `vercel login` → `vercel` → `vercel --prod`\n- Backend: files in /api. Env: `vercel env add NAME production`. DB: Neon/Supabase/Upstash via DATABASE_URL.\n\n## Firebase Hosting (+ Functions + Firestore)\n- `npm i -g firebase-tools` → `firebase login` → `firebase init hosting` (public=" + pub + ", SPA=yes)\n- `npm run build` → `firebase deploy --only hosting`\n- Backend: `firebase init functions`; route /api/** ABOVE the SPA catch-all. DB: `firebase init firestore`, default-deny rules.\n\n## Cloud Run\n- App MUST listen on process.env.PORT (8080) on 0.0.0.0.\n- `gcloud auth login` → `gcloud config set project ID`\n- `gcloud run deploy " + svc + " --source . --region " + reg + " --allow-unauthenticated`\n\n## GitHub + CI/CD\n- Keep the project in a private GitHub repo; GitHub Actions deploys every push to main.\n\n## Pre-launch\n- Secrets in the platform store, .env* gitignored. Firestore/Storage rules default-deny. Backend binds $PORT. Custom domain + HTTPS auto. Cap instances; smoke-test the live URL.\n";
    }

    // ---- subscriptions ----
    string SaasSubKey()
    {
        string s = (saasSubProvider.SelectedItem ?? "").ToString();
        if (s.StartsWith("Lemon")) return "lemonsqueezy";
        if (s.StartsWith("Tap")) return "tap";
        if (s.StartsWith("Moyasar")) return "moyasar";
        return "stripe";
    }
    void SaasScaffoldSubscriptions()
    {
        if (!SaasDeployDirValid()) return;
        string dir = SaasDeployDir();
        try
        {
            File.WriteAllText(Path.Combine(dir, "SUBSCRIPTIONS.md"), SaasSubscriptionSpec());
            File.WriteAllText(Path.Combine(dir, "EMAIL.md"), SaasEmailSpec());
            File.WriteAllText(Path.Combine(dir, ".env.subscriptions.example"), SaasSubEnvExample());
            SaasLog("Wrote SUBSCRIPTIONS.md, EMAIL.md and .env.subscriptions.example into " + dir);
            SaasLog("Fill the keys, then Build with " + SaasBuilderName() + " to implement the full billing + email flow.");
        }
        catch (Exception ex) { SaasLog("Scaffold failed: " + ex.Message); }
    }
    void SaasBuildSubsWithClaude()
    {
        if (!SaasDeployDirValid()) return;
        string dir = SaasDeployDir();
        try { File.WriteAllText(Path.Combine(dir, "SUBSCRIPTIONS.md"), SaasSubscriptionSpec()); File.WriteAllText(Path.Combine(dir, "EMAIL.md"), SaasEmailSpec()); }
        catch (Exception ex) { SaasLog("Could not write specs: " + ex.Message); return; }
        string prompt = "Read SUBSCRIPTIONS.md and EMAIL.md in this folder and implement the full subscription infrastructure they describe (checkout, signed webhooks, entitlement checks, customer portal) plus the subscriber email flows (transactional + broadcast with unsubscribe). This is an Open SaaS (Wasp) app (" + SaasTemplateRepo + ") — follow its conventions (main.wasp operations, Prisma entities, src/server) and its payments plumbing where it fits. Use the database as the source of truth. Summarize the plan, then build it incrementally and keep it runnable." + SaasSkillsHint();
        SaasLaunchBuilder(dir, prompt);
        SaasLog("Wrote the specs and opened " + SaasBuilderName() + " in the Workspace to build the subscription + email system.");
    }
    void SaasOpenBillingDocs()
    {
        string url;
        switch (SaasSubKey()) { case "tap": url = "https://developers.tap.company/"; break; case "moyasar": url = "https://docs.moyasar.com/"; break; case "lemonsqueezy": url = "https://docs.lemonsqueezy.com/"; break; default: url = "https://docs.stripe.com/billing/subscriptions/overview"; break; }
        try { Process.Start(url); } catch { }
    }
    string SaasSubscriptionSpec()
    {
        string key = SaasSubKey();
        string trial = (saasTrial.Text ?? "14").Trim(); if (trial.Length == 0) trial = "14";
        var sb = new StringBuilder();
        sb.AppendLine("# Subscription infrastructure — " + (saasName.Text ?? "").Trim());
        sb.AppendLine();
        sb.AppendLine("- Provider: **" + saasSubProvider.SelectedItem + "**");
        sb.AppendLine("- Free trial: **" + trial + " days**");
        sb.AppendLine("- Plans / tiers:");
        foreach (var l in (saasTiers.Text ?? "").Replace("\r", "").Split('\n')) if (l.Trim().Length > 0) sb.AppendLine("  - " + l.Trim());
        sb.AppendLine();
        sb.AppendLine("## Architecture (build all four pillars)");
        sb.AppendLine("1. Checkout to start a subscription.");
        sb.AppendLine("2. Signed webhooks → update the DB (source of truth for entitlement).");
        sb.AppendLine("3. Entitlement check in the app (read the DB, never the client).");
        sb.AppendLine("4. Customer Portal / self-service for upgrade/cancel/card update.");
        sb.AppendLine();
        if (key == "stripe")
            sb.AppendLine("## Stripe\n- Create products + prices; store `price_...` ids in env by plan.\n- Checkout: `stripe.checkout.sessions.create({ mode: \"subscription\", customer, line_items:[{price,quantity:1}], subscription_data:{ trial_period_days: " + trial + " }, success_url, cancel_url, client_reference_id: userId })`.\n- Webhook `/api/webhooks/stripe`: verify with the RAW body + `STRIPE_WEBHOOK_SECRET`; handle `checkout.session.completed`, `customer.subscription.updated/deleted`, `invoice.payment_failed`. Idempotent on `event.id`.\n- Portal: `stripe.billingPortal.sessions.create({ customer, return_url })`.\n- Entitlement: `[\"active\",\"trialing\"].includes(status) && currentPeriodEnd > now`.\n- Test locally: `stripe listen --forward-to localhost:3000/api/webhooks/stripe`.");
        else if (key == "lemonsqueezy")
            sb.AppendLine("## Lemon Squeezy\n- Create subscription products and variants in the Lemon Squeezy dashboard; store variant IDs in env by plan.\n- Checkout: create a checkout for the selected variant and pass the app user ID as custom data.\n- Webhook `/api/webhooks/lemonsqueezy`: verify `X-Signature` with `LEMONSQUEEZY_WEBHOOK_SECRET`; handle subscription created, updated, cancelled, expired, payment success, and payment failed events. Idempotent on the event ID.\n- Portal: send users to the Lemon Squeezy customer portal / subscription management URL.\n- Entitlement: active/trialing/past_due states plus currentPeriodEnd > now; use the database as the source of truth.");
        else if (key == "tap")
            sb.AppendLine("## Tap Payments (KSA) — recurring\n- Amount in MAJOR units (10.00 SAR = 10.00). Auth: Authorization: Bearer sk_ (server only).\n- Save a card token via the Card SDK, then charge the saved token on your own schedule (a cron each period). Your DB holds subscription state.\n- Webhook: verify the hashstring HMAC before trusting status == CAPTURED. Methods: mada, Apple Pay, STC Pay, cards.");
        else
            sb.AppendLine("## Moyasar (KSA) — recurring\n- Amount in HALALAS (10.00 SAR = 1000, x100). Auth: HTTP Basic, secret key as username, empty password.\n- Save a token source, then POST /payments with source.type = token on your billing cadence (cron). Your DB holds subscription state.\n- Webhook: verify secret_token before marking a payment paid. Methods: creditcard (Visa/Mastercard/mada), Apple Pay, STC Pay.");
        sb.AppendLine();
        sb.AppendLine("Data model: User { billingCustomerId, plan, subscriptionStatus, currentPeriodEnd, cancelAtPeriodEnd, emailOptIn }, WebhookEvent { id, processedAt }.");
        sb.AppendLine("See the bundled `subscription-billing` skill for full code. Keep secrets server-side.");
        return sb.ToString();
    }
    string SaasEmailSpec()
    {
        string prov = (saasEmailProvider.SelectedItem ?? "Resend").ToString();
        var sb = new StringBuilder();
        sb.AppendLine("# Subscriber email — " + (saasName.Text ?? "").Trim());
        sb.AppendLine();
        sb.AppendLine("- Provider: **" + prov + "**");
        sb.AppendLine("- From: **" + (saasFromEmail.Text ?? "").Trim() + "**");
        sb.AppendLine();
        sb.AppendLine("## Two jobs — keep them separate");
        sb.AppendLine("1. Transactional (one recipient, event-driven): welcome, receipt, payment-failed, trial-ending. Wire to billing webhook events.");
        sb.AppendLine("2. Broadcast (many recipients): newsletters / product updates to opted-in paid users. Must include one-click unsubscribe.");
        sb.AppendLine();
        if (prov == "Postmark") sb.AppendLine("## Postmark\n- npm i postmark. Separate message streams for transactional vs broadcast.\n- new ServerClient(POSTMARK_TOKEN).sendEmail({ From, To, Subject, HtmlBody, MessageStream }).");
        else if (prov == "SendGrid") sb.AppendLine("## SendGrid\n- npm i @sendgrid/mail. Transactional via sgMail.send(...); broadcasts via Marketing Campaigns.");
        else sb.AppendLine("## Resend\n- npm i resend. resend.emails.send({ from, to, subject, html }) for transactional; resend.batch.send([...]) / Broadcasts for campaigns.");
        sb.AppendLine();
        sb.AppendLine("## Deliverability (non-negotiable)");
        sb.AppendLine("- Verify the sending domain: add SPF + DKIM + DMARC DNS records.");
        sb.AppendLine("- Every broadcast needs one-click unsubscribe (List-Unsubscribe header + footer). Store opt-outs; never re-send.");
        sb.AppendLine("- Separate transactional and marketing streams/subdomains. Track bounces/complaints and suppress bad addresses.");
        sb.AppendLine();
        sb.AppendLine("Audience query: paid + opted-in — where subscriptionStatus in (active,trialing) and emailOptIn = true. See the bundled `subscription-billing` skill for code.");
        return sb.ToString();
    }
    string SaasSubEnvExample()
    {
        var lines = new List<string>();
        switch (SaasSubKey())
        {
            case "tap": lines.Add("TAP_SECRET_KEY=sk_test_xxx"); lines.Add("TAP_PUBLISHABLE_KEY=pk_test_xxx"); break;
            case "moyasar": lines.Add("MOYASAR_SECRET_KEY=sk_test_xxx"); lines.Add("MOYASAR_PUBLISHABLE_KEY=pk_test_xxx"); break;
            case "lemonsqueezy": lines.Add("LEMONSQUEEZY_API_KEY=xxx"); lines.Add("LEMONSQUEEZY_WEBHOOK_SECRET=xxx"); lines.Add("LEMONSQUEEZY_STORE_ID=xxx"); lines.Add("LEMONSQUEEZY_VARIANT_PRO_MONTHLY=xxx"); lines.Add("LEMONSQUEEZY_VARIANT_PRO_YEARLY=xxx"); break;
            default: lines.Add("STRIPE_SECRET_KEY=sk_test_xxx"); lines.Add("STRIPE_WEBHOOK_SECRET=whsec_xxx"); lines.Add("STRIPE_PRICE_PRO_MONTHLY=price_xxx"); lines.Add("STRIPE_PRICE_PRO_YEARLY=price_xxx"); lines.Add("NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY=pk_test_xxx"); break;
        }
        string prov = (saasEmailProvider.SelectedItem ?? "Resend").ToString();
        if (prov == "Postmark") lines.Add("POSTMARK_SERVER_TOKEN=xxx");
        else if (prov == "SendGrid") lines.Add("SENDGRID_API_KEY=SG.xxx");
        else lines.Add("RESEND_API_KEY=re_xxx");
        lines.Add("APP_URL=https://your.app");
        lines.Add("EMAIL_FROM=" + (saasFromEmail.Text ?? "").Trim());
        return "# Never commit real values — add .env* to .gitignore\n" + string.Join("\n", lines.ToArray()) + "\n";
    }


    void SaasLog(string line) { try { saasStatus.AppendText("\r\n" + line); } catch { } }

    // Nudge the selected builder to USE the bundled skills that fit the task.
    string SaasSkillsHint()
    {
        return " Before you start, check which " + (SaasBuilderName() == "ChatGPT" ? "Codex" : "Claude") + " skills are installed and USE every one that fits: "
            + "design-taste-frontend / high-end-visual-design / industrial-brutalist-ui for premium, non-templated UI; "
            + "imagegen-frontend-web / imagegen-frontend-mobile / brandkit for visuals and brand; "
            + "image-to-code for turning designs into code; full-output-enforcement so nothing is left as a stub; "
            + "cloud-deployment when deploying; subscription-billing for payments and subscriber email; "
            + "ai-integration for the multi-provider AI router (OpenRouter + Groq + free providers, best→cheapest fallback); "
            + "karpathy-guidelines / gpt-taste for clean code; stop-slop for ALL user-facing copy (landing, emails, empty states) so nothing reads AI-written. Load each skill BEFORE its phase of work (PLAYBOOK.md maps skills to phases), not after.";
    }

    string SaasAppDir() { return Path.Combine((saasFolder.Text ?? "").Trim(), (saasName.Text ?? "").Trim()); }

    // ---- presets: common SaaS types that pre-fill the vision so beginners start fast ----
    bool saasLoading;   // suppress preset side-effects while restoring the saved form
    void ApplySaasPreset(string p)
    {
        if (saasLoading) return;
        switch (p)
        {
            case "Property rentals (KSA)":
                saasPitch.Text = "Rental property management for Saudi landlords — leases, rent collection, and maintenance in one place";
                saasFeatures.Text = "Property & unit directory with photos\r\nLease contracts (Ejar-ready fields, Hijri + Gregorian dates)\r\nRent collection via payment links (mada / Apple Pay)\r\nAutomatic late-payment reminders (SMS/WhatsApp)\r\nMaintenance requests with photo upload + vendor assignment\r\nOwner dashboard: occupancy, collections, expiring leases\r\nArabic + English interface (RTL)";
                saasTiers.Text = "Starter — 99 SAR/mo (10 units)\r\nPortfolio — 249 SAR/mo (50 units)\r\nEnterprise — 699 SAR/mo (unlimited + owner portals)";
                break;
            case "Restaurant QR menu":
                saasPitch.Text = "QR menus and table ordering for restaurants and cafés — guests scan, order, and pay from their phone";
                saasFeatures.Text = "Menu builder with photos, variants, and modifiers (Arabic + English)\r\nQR code per table; dine-in, pickup, and delivery modes\r\nGuest ordering page (no app install) with mada / Apple Pay / STC Pay\r\nLive kitchen order screen with statuses\r\nDaily sales dashboard + best-sellers\r\nVAT-ready receipts (ZATCA QR)\r\nHappy-hour scheduling and item availability toggles";
                saasTiers.Text = "Solo — 79 SAR/mo (1 branch)\r\nChain — 199 SAR/mo (5 branches)\r\nFranchise — 499 SAR/mo (unlimited + API)";
                break;
            case "Clinic bookings":
                saasPitch.Text = "Appointments and patient records for private clinics — booking, reminders, and visit notes without the paperwork";
                saasFeatures.Text = "Public booking page per doctor with real-time slots\r\nPatient records: visits, notes, attachments, allergies\r\nSMS/WhatsApp appointment reminders (cuts no-shows)\r\nWalk-in queue screen for the waiting room\r\nInvoices with VAT + insurance claim export\r\nStaff roles: doctor, reception, admin\r\nArabic + English, fully RTL";
                saasTiers.Text = "Solo doctor — 149 SAR/mo\r\nClinic — 349 SAR/mo (5 practitioners)\r\nPolyclinic — 899 SAR/mo (unlimited + multi-branch)";
                break;
            case "Umrah trip organizer":
                saasPitch.Text = "Group trip management for Umrah operators — packages, pilgrim records, payments, and live coordination";
                saasFeatures.Text = "Package builder: hotels, transport, dates, pricing\r\nPilgrim registration with passport/visa document upload\r\nInstallment payment plans with payment links\r\nGroup manifest: rooming lists, bus assignments\r\nWhatsApp broadcast to the group (gate changes, schedules)\r\nExpense tracking per trip + profit report\r\nArabic-first interface";
                saasTiers.Text = "Starter — 199 SAR/mo (2 active groups)\r\nOperator — 499 SAR/mo (10 groups)\r\nAgency — 1,199 SAR/mo (unlimited + sub-agents)";
                break;
            case "Real-estate CRM":
                saasPitch.Text = "A deals CRM for real-estate brokers in the Gulf — listings, leads, viewings, and commissions in one pipeline";
                saasFeatures.Text = "Listings with photos, map location, and owner details\r\nLead capture from WhatsApp / web forms with auto-assignment\r\nPipeline board: new → viewing → offer → closed\r\nViewing scheduler with reminders\r\nCommission calculator + closed-deals report\r\nOwner/landlord portal with offer updates\r\nArabic + English (RTL)";
                saasTiers.Text = "Agent — 99 SAR/mo (1 seat)\r\nOffice — 299 SAR/mo (10 seats)\r\nBrokerage — 699 SAR/mo (unlimited + team analytics)";
                break;
            case "HR & payroll (KSA)":
                saasPitch.Text = "HR and payroll for Saudi SMEs — contracts, GOSI, leave, and WPS payroll files without spreadsheets";
                saasFeatures.Text = "Employee records: contracts, iqama/ID expiry alerts\r\nPayroll runs with GOSI calculation and payslips\r\nWPS-compatible bank file export (mudad-style)\r\nLeave requests + balances (annual, sick, Hajj)\r\nEnd-of-service (EOS) benefit calculator per Saudi labor law\r\nAttendance import + overtime rules\r\nSaudization (Nitaqat) headcount dashboard";
                saasTiers.Text = "Starter — 149 SAR/mo (10 employees)\r\nBusiness — 399 SAR/mo (50 employees)\r\nCorporate — 999 SAR/mo (unlimited + multi-entity)";
                break;
            case "WhatsApp storefront":
                saasPitch.Text = "A storefront that sells where Gulf customers already are — catalog, checkout, and order updates over WhatsApp";
                saasFeatures.Text = "Product catalog page with Arabic + English descriptions\r\nOne-tap \"Order on WhatsApp\" with pre-filled cart message\r\nPayment links (mada / STC Pay / Apple Pay) sent in-chat\r\nOrder tracker: new → confirmed → out for delivery\r\nCash-on-delivery support with driver reconciliation\r\nAbandoned-cart WhatsApp nudges\r\nInstagram-bio-ready store link";
                saasTiers.Text = "Seller — 49 SAR/mo (100 orders)\r\nShop — 149 SAR/mo (1,000 orders)\r\nBrand — 399 SAR/mo (unlimited + API)";
                break;
            case "Quran & tutoring academy":
                saasPitch.Text = "Run a Quran memorization or tutoring academy online — sessions, hifz progress, and parent reports";
                saasFeatures.Text = "Student profiles with level and goals\r\nSession scheduling (1:1 and halaqa groups) with Zoom/Meet links\r\nHifz progress tracker: surah/juz, revision cycles, tajweed notes\r\nParent portal with weekly progress reports\r\nTeacher payouts based on delivered sessions\r\nMonthly subscriptions with family discounts\r\nArabic-first, Hijri calendar aware";
                saasTiers.Text = "Teacher — 69 SAR/mo (20 students)\r\nAcademy — 199 SAR/mo (150 students)\r\nInstitute — 499 SAR/mo (unlimited + branches)";
                break;
            case "Event ticketing":
                saasPitch.Text = "Ticketing for events in the Gulf — weddings, conferences, and shows with QR check-in and Arabic invites";
                saasFeatures.Text = "Event pages with Arabic + English details\r\nTicket tiers, promo codes, and seat/table assignment\r\nPayment via mada / Apple Pay / STC Pay\r\nQR ticket delivery over WhatsApp + email\r\nDoor check-in app with live attendance count\r\nGuest-list import for private events (weddings)\r\nPost-event analytics + attendee export";
                saasTiers.Text = "Organizer — 99 SAR/mo + 2 SAR/ticket\r\nPro — 299 SAR/mo + 1 SAR/ticket\r\nVenue — 799 SAR/mo (unlimited events)";
                break;
            case "Charity & zakat":
                saasPitch.Text = "Donation and zakat campaign management for charities — collect, track, and report with full transparency";
                saasFeatures.Text = "Campaign pages with progress bars (Arabic + English)\r\nOne-time + recurring donations (mada / Apple Pay / STC Pay)\r\nZakat calculator that feeds straight into checkout\r\nAutomatic donation receipts (VAT-exempt format)\r\nRamadan mode: daily giving + iftar sponsorships\r\nDonor CRM with giving history + gift-aid style reports\r\nBoard-ready transparency reports per campaign";
                saasTiers.Text = "Small charity — 149 SAR/mo\r\nFoundation — 399 SAR/mo (unlimited campaigns)\r\nEnterprise — custom (multi-org + audits)";
                break;
            case "Tadawul paper trading (AI)":
                saasPitch.Text = "Risk-free paper trading for the Saudi stock market — practice on live Tadawul prices with an AI coach explaining every move";
                saasFeatures.Text = "Virtual portfolio with 100k SAR starting balance (delayed Tadawul quotes)\r\nBuy/sell simulator with real tickers, order types, and TASI index tracking\r\nAI trade coach: explains each stock, flags risky trades, and reviews your week\r\nShariah-compliance badge on every stock (halal screening)\r\nLeaderboards and monthly trading competitions\r\nLearning path: candlesticks, dividends, sukuk vs stocks (Arabic + English)\r\nWatchlists with price alerts over WhatsApp/email\r\nPerformance analytics vs TASI benchmark";
                saasTiers.Text = "Learner — 0 SAR (1 portfolio, delayed data)\r\nTrader — 89 SAR/mo (AI coach + competitions)\r\nPro — 249 SAR/mo (multiple portfolios + advanced analytics + API)";
                break;
            case "AI web scraping service":
                saasPitch.Text = "AI-powered web scraping as a service — customers describe the data they want in plain language and get clean, structured results on a schedule";
                saasFeatures.Text = "Plain-language scrape builder: paste a URL, describe the data, AI writes the extractor\r\nSelf-healing scrapers: AI re-maps selectors when a site changes layout\r\nScheduled runs (hourly/daily/weekly) with diff detection — get only what changed\r\nClean output: CSV, JSON, Google Sheets sync, and webhook delivery\r\nProxy rotation + polite rate limiting built in (respects robots.txt)\r\nPre-built recipes: e-commerce prices, real-estate listings, job posts, competitor monitoring\r\nUsage-based credits with a live cost estimator\r\nAPI + Zapier/Make integration for pipelines";
                saasTiers.Text = "Starter — 0 SAR (2 scrapers, 100 pages/mo)\r\nGrowth — 149 SAR/mo (20 scrapers, 10k pages)\r\nScale — 449 SAR/mo (unlimited scrapers, 100k pages + API)";
                break;
            case "AI tool":
                saasPitch.Text = "An AI assistant that <does one job> for <audience> in seconds";
                saasFeatures.Text = "Landing page with live demo\r\nPrompt workspace (input → AI result)\r\nHistory of past generations\r\nUsage credits per plan\r\nAccount & billing page";
                saasTiers.Text = "Free — 0 SAR (20 credits/mo)\r\nPro — 79 SAR/mo (2,000 credits)\r\nTeam — 249 SAR/mo (10,000 credits, 5 seats)";
                break;
            case "Marketplace":
                saasPitch.Text = "A marketplace connecting <sellers> with <buyers> in KSA";
                saasFeatures.Text = "Public listings with search + filters\r\nSeller onboarding & profile pages\r\nListing creation with photos\r\nOrders + status tracking\r\nAdmin approval dashboard\r\nReviews & ratings";
                saasTiers.Text = "Free — 0 SAR (browse & buy)\r\nSeller — 99 SAR/mo (unlimited listings)\r\nSeller Pro — 299 SAR/mo (featured placement + analytics)";
                break;
            case "Booking & appointments":
                saasPitch.Text = "Online booking for <service providers> — customers book, pay, and get reminders";
                saasFeatures.Text = "Public booking page per provider\r\nCalendar with availability rules\r\nDeposits / prepayment at booking\r\nSMS + email reminders\r\nStaff & services management\r\nNo-show and cancellation policies";
                saasTiers.Text = "Solo — 49 SAR/mo (1 calendar)\r\nStudio — 149 SAR/mo (5 staff)\r\nChain — 399 SAR/mo (unlimited, multi-branch)";
                break;
            case "Invoicing & finance":
                saasPitch.Text = "ZATCA-friendly invoicing for freelancers and small businesses in KSA";
                saasFeatures.Text = "Client directory\r\nInvoice editor with VAT + QR (ZATCA phase 1)\r\nPayment links (pay invoice online)\r\nExpense tracking\r\nMonthly reports & export\r\nRecurring invoices";
                saasTiers.Text = "Starter — 0 SAR (3 invoices/mo)\r\nBusiness — 69 SAR/mo (unlimited + payment links)\r\nFirm — 199 SAR/mo (multi-user + API)";
                break;
            case "Courses & learning":
                saasPitch.Text = "Sell online courses with lessons, quizzes, and certificates";
                saasFeatures.Text = "Course catalog + landing pages\r\nVideo lessons with progress tracking\r\nQuizzes and completion certificates\r\nStudent dashboard\r\nInstructor analytics\r\nDrip content by week";
                saasTiers.Text = "Student — free (enrolled courses)\r\nCreator — 99 SAR/mo (3 courses)\r\nAcademy — 299 SAR/mo (unlimited + team)";
                break;
            case "Team dashboard":
                saasPitch.Text = "An internal ops dashboard that gives <team> one place to track <workflow>";
                saasFeatures.Text = "SSO login (Google)\r\nKPI overview with charts\r\nRecords table with filters + bulk actions\r\nRole-based access (admin/member/viewer)\r\nAudit log\r\nCSV import/export";
                saasTiers.Text = "Team — 149 SAR/mo (10 seats)\r\nBusiness — 399 SAR/mo (50 seats + SSO)\r\nEnterprise — contact us";
                break;
            default: return;   // Custom: leave the user's text alone
        }
        SaasLog("Applied the \"" + p + "\" preset — tweak the pitch, features, and tiers to make it yours.");
    }

    // ---- persistence: the form survives app restarts (StateDir\saas-form.txt) ----
    bool saasDirty;
    string SaasFormFile { get { return Path.Combine(StateDir, "saas-form.txt"); } }
    static string EncNL(string s) { return (s ?? "").Replace("\r\n", "\\n").Replace("\n", "\\n"); }
    static string DecNL(string s) { return (s ?? "").Replace("\\n", "\r\n"); }

    void SaveSaasForm()
    {
        try
        {
            var sb = new StringBuilder();
            sb.AppendLine("name=" + saasName.Text); sb.AppendLine("parent=" + saasFolder.Text);
            sb.AppendLine("builder=" + saasBuildAgent.Text); sb.AppendLine("model=" + saasBuildModel.Text); sb.AppendLine("preset=" + saasPreset.Text);
            sb.AppendLine("pitch=" + EncNL(saasPitch.Text)); sb.AppendLine("features=" + EncNL(saasFeatures.Text));
            sb.AppendLine("auth=" + saasAuth.Text); sb.AppendLine("pay=" + saasPay.Text);
            sb.AppendLine("ai=" + saasAI.Text);
            sb.AppendLine("target=" + saasTarget.Text); sb.AppendLine("backend=" + saasBackend.Text);
            sb.AppendLine("region=" + saasRegion.Text); sb.AppendLine("publicDir=" + saasPublicDir.Text);
            sb.AppendLine("gcpProject=" + saasGcpProject.Text); sb.AppendLine("serviceName=" + saasServiceName.Text);
            sb.AppendLine("repoVis=" + saasRepoVis.Text); sb.AppendLine("subProvider=" + saasSubProvider.Text);
            sb.AppendLine("tiers=" + EncNL(saasTiers.Text)); sb.AppendLine("trial=" + saasTrial.Text);
            sb.AppendLine("emailProvider=" + saasEmailProvider.Text); sb.AppendLine("fromEmail=" + saasFromEmail.Text);
            File.WriteAllText(SaasFormFile, sb.ToString());
        }
        catch { }
    }

    void LoadSaasForm()
    {
        try
        {
            if (!File.Exists(SaasFormFile)) return;
            saasLoading = true;
            foreach (var line in File.ReadAllLines(SaasFormFile))
            {
                int i = line.IndexOf('=');
                if (i <= 0) continue;
                string k = line.Substring(0, i), v = line.Substring(i + 1);
                if (v.Length == 0) continue;
                switch (k)
                {
                    case "name": saasName.Text = v; break;
                    case "parent": saasFolder.Text = v; break;
                    case "builder": if (v == "Claude" || v == "ChatGPT") { saasBuildAgent.Text = v; RefreshSaasBuildModelChoices(); } break;
                    case "model": saasBuildModel.Text = v; break;
                    case "preset": saasPreset.SelectedItem = v; break;
                    case "pitch": saasPitch.Text = DecNL(v); break;
                    case "features": saasFeatures.Text = DecNL(v); break;
                    case "auth": saasAuth.SelectedItem = v; break;
                    case "pay": saasPay.SelectedItem = v; break;
                    case "ai": saasAI.SelectedItem = v; break;
                    case "target": saasTarget.SelectedItem = v; break;
                    case "backend": saasBackend.SelectedItem = v; break;
                    case "region": saasRegion.SelectedItem = v; break;
                    case "publicDir": saasPublicDir.Text = v; break;
                    case "gcpProject": saasGcpProject.Text = v; break;
                    case "serviceName": saasServiceName.Text = v; break;
                    case "repoVis": saasRepoVis.SelectedItem = v; break;
                    case "subProvider": saasSubProvider.SelectedItem = v; break;
                    case "tiers": saasTiers.Text = DecNL(v); break;
                    case "trial": saasTrial.Text = v; break;
                    case "emailProvider": saasEmailProvider.SelectedItem = v; break;
                    case "fromEmail": saasFromEmail.Text = v; break;
                }
            }
        }
        catch { }
        finally { saasLoading = false; saasDirty = false; }
    }

    // ---- live launch checklist derived from the project folder ----
    void UpdateSaasProgress()
    {
        try
        {
            if (saasDirty) { saasDirty = false; SaveSaasForm(); }
            if (saasProgress == null) return;
            string dir = SaasAppDir();
            Func<bool, string, string> mk = (ok, label) => (ok ? "✓ " : "○ ") + label;
            bool scaffolded = File.Exists(Path.Combine(dir, "main.wasp")) || File.Exists(Path.Combine(dir, "package.json"))
                || File.Exists(Path.Combine(dir, "app", "main.wasp"));
            string gitCfg = "";
            try { string gp = Path.Combine(dir, ".git", "config"); if (File.Exists(gp)) gitCfg = File.ReadAllText(gp); } catch { }
            string wf = Path.Combine(dir, ".github", "workflows");
            bool hasWorkflow = Directory.Exists(wf) && Directory.GetFiles(wf).Length > 0;
            bool deployCfg = File.Exists(Path.Combine(dir, "vercel.json")) || File.Exists(Path.Combine(dir, "firebase.json")) || File.Exists(Path.Combine(dir, "Dockerfile"));
            saasProgress.Text = "Progress:   " + string.Join("   ·   ", new[] {
                mk(Directory.Exists(dir), "App folder"),
                mk(File.Exists(Path.Combine(dir, "VISION.md")), "Vision"),
                mk(scaffolded, "Scaffolded"),
                mk(gitCfg.Contains("github.com"), "GitHub"),
                mk(hasWorkflow, "CI/CD"),
                mk(deployCfg, "Deploy config"),
                mk(File.Exists(Path.Combine(dir, "SUBSCRIPTIONS.md")), "Billing"),
                mk(File.Exists(Path.Combine(dir, "ANALYTICS.md")), "Analytics")
            });
        }
        catch { }
    }

    // ---- ⚡ instant mode: one click, Claude orchestrates the whole lifecycle ----

    // The Open SaaS template repo — the MANDATORY base for every build, whatever the use case.
    const string SaasTemplateRepo = "https://github.com/wasp-lang/open-saas";

    // The exact stack the ⚡ instant build will use — shown to the user BEFORE anything runs.
    string SaasStackSummary()
    {
        string n = (saasName.Text ?? "").Trim(); if (n.Length == 0) n = "my-saas";
        string t = (saasTarget.SelectedItem ?? "Vercel").ToString();
        var sb = new StringBuilder();
        sb.AppendLine("Template:   Open SaaS — " + SaasTemplateRepo + " (always, every use case)");
        sb.AppendLine("Framework:  Wasp · React · Node.js · Prisma · PostgreSQL · Tailwind CSS");
        sb.AppendLine("App:        " + n + "  →  " + SaasAppDir());
        sb.AppendLine("Preset:     " + (saasPreset.SelectedItem ?? "Custom"));
        sb.AppendLine("Auth:       " + (saasAuth.SelectedItem ?? ""));
        sb.AppendLine("Payments:   " + (saasPay.SelectedItem ?? ""));
        sb.AppendLine("AI layer:   " + (saasAI.SelectedItem ?? ""));
        sb.AppendLine("Analytics:  Google Analytics 4 — always on, cookie-consent gated (every use case)");
        sb.AppendLine("Deploy:     " + t + " · backend: " + (saasBackend.SelectedItem ?? "") + (t == "Cloud Run" ? " · " + saasRegion.SelectedItem : ""));
        sb.AppendLine("GitHub:     " + (saasRepoVis.SelectedItem ?? "Private").ToString().ToLower() + " repo + Actions CI/CD");
        sb.AppendLine("Billing:    " + (saasSubProvider.SelectedItem ?? "") + " · " + (saasTrial.Text ?? "14").Trim() + "-day trial · email via " + (saasEmailProvider.SelectedItem ?? ""));
        sb.AppendLine("Builder:    " + SaasBuilderName());
        sb.AppendLine("Model:      " + (saasBuildModel.Text.Length > 0 ? saasBuildModel.Text : "Default"));
        return sb.ToString();
    }

    // Keep the on-screen stack preview in sync with the form (mirrors the Mac live preview).
    void RefreshSaasStackPreview()
    {
        try { if (saasStackPreview != null) saasStackPreview.Text = SaasStackSummary().TrimEnd(); } catch { }
    }

    void SaasBuildEverything()
    {
        string n = (saasName.Text ?? "").Trim();
        string p = (saasFolder.Text ?? "").Trim();
        if (n.Length == 0 || !Directory.Exists(p)) { MessageBox.Show("Set a valid parent folder and app name first.", "Hydra"); return; }
        if ((saasPitch.Text ?? "").Trim().Length == 0) { MessageBox.Show("Write the one-line pitch (or pick a template) so Claude knows what to build.", "Hydra"); return; }
        // Show the exact stack and get an explicit OK before anything is written or launched.
        if (MessageBox.Show(SaasStackSummary() + "\n" + SaasBuilderName() + " will scaffold Open SaaS, build every feature, wire billing + email, create the GitHub repo, and deploy — in one run.",
                "⚡ Instant build — confirm your stack", MessageBoxButtons.OKCancel, MessageBoxIcon.Question) != DialogResult.OK)
        { SaasLog("Instant build cancelled — adjust the stack and press ⚡ again when ready."); return; }
        string app = SaasAppDir();
        try
        {
            Directory.CreateDirectory(app);
            // Write EVERY spec up front so one Claude session has the full picture.
            File.WriteAllText(Path.Combine(app, "PLAYBOOK.md"), PlaybookDoc());
            File.WriteAllText(Path.Combine(app, "VISION.md"), BuildVisionDoc());
            string pkey = PaymentKey();
            if (pkey != "none") File.WriteAllText(Path.Combine(app, "PAYMENTS.md"), PaymentSpec(pkey));
            File.WriteAllText(Path.Combine(app, "DEPLOY.md"), SaasDeploySpec());
            File.WriteAllText(Path.Combine(app, "SUBSCRIPTIONS.md"), SaasSubscriptionSpec());
            File.WriteAllText(Path.Combine(app, "EMAIL.md"), SaasEmailSpec());
            File.WriteAllText(Path.Combine(app, "ANALYTICS.md"), AnalyticsSpec());
            File.WriteAllText(Path.Combine(app, ".env.analytics.example"), AnalyticsEnvExample());
            File.WriteAllText(Path.Combine(app, ".env.subscriptions.example"), SaasSubEnvExample());
            if (AiEnabled())
            {
                File.WriteAllText(Path.Combine(app, "AI.md"), AiSpec());
                File.WriteAllText(Path.Combine(app, ".env.ai.example"), AiEnvExample());
            }
        }
        catch (Exception ex) { SaasLog("Could not write specs: " + ex.Message); return; }
        SaasLog("Wrote VISION.md, DEPLOY.md, SUBSCRIPTIONS.md, EMAIL.md, ANALYTICS.md" + (AiEnabled() ? ", AI.md" : "") + " into " + app);
        SaveSaasForm();
        string vis = (saasRepoVis.SelectedItem ?? "Private").ToString().ToLower();
        string prompt = "You are building a complete SaaS end-to-end in this folder. FIRST read PLAYBOOK.md — the battle-tested production sequence (accounts first, deploy the skeleton early, known pitfalls with exact fixes, Namecheap domain linking); follow its phase order and rules throughout. Then read VISION.md, PAYMENTS.md (if present), AI.md (if present), SUBSCRIPTIONS.md, EMAIL.md, ANALYTICS.md and DEPLOY.md, then do ALL of it in order: "
            + "(1) If the app is not scaffolded yet (no main.wasp/package.json), scaffold the Open SaaS template (" + SaasTemplateRepo + ") here with `wasp new " + n + " -t saas` — the wasp CLI is available as `wasp` (if the folder having these .md files blocks `wasp new`, scaffold in a temp dir and move the result in, keeping the .md files). Open SaaS is the MANDATORY base for EVERY use case — never substitute Next.js, plain Vite, CRA, or any other starter. "
            + "(2) Build the product in VISION.md: auth, every feature/page, premium non-templated UI. If AI.md is present, add its multi-provider router (src/server/ai/router.ts) with the best→cheapest priority ladder and route EVERY AI feature through it. Wire Google Analytics 4 per ANALYTICS.md — it is mandatory for every use case: consent-gated gtag via Open SaaS's cookie-consent banner, the required events, and the admin-dashboard stats job (env ids stubbed, never real). "
            + "(3) Implement the subscription billing + subscriber email described in SUBSCRIPTIONS.md and EMAIL.md, with env keys stubbed in .env.server (never real secrets). "
            + "(4) Initialize git, create a " + vis + " GitHub repo with `gh`, and add the GitHub Actions workflow per DEPLOY.md. "
            + "(5) Deploy to " + saasTarget.SelectedItem + " per DEPLOY.md and report the live URL. "
            + "Work through this as one continuous mission; verify each stage works before the next; ask me only when a decision is truly mine (accounts, payments, spend)."
            + SaasSkillsHint();
        SaasLaunchBuilder(app, prompt);
        SaasLog("⚡ Instant build started — " + SaasBuilderName() + " is orchestrating scaffold → build → billing → GitHub → deploy in the Workspace.");
    }

    void SaasCheckWasp()
    {
        bool wsl = OnPath("wsl.exe");
        if (OnPath("wasp.exe") || OnPath("wasp"))
        { saasStatus.Text = "Wasp CLI found on PATH. You can go to step 2."; return; }
        saasStatus.Text = "Wasp CLI not found.";
        SaasLog("Wasp runs on macOS/Linux/WSL. On Windows it needs WSL.");
        SaasLog(wsl ? "WSL detected. Installing inside WSL…" : "WSL not detected — install it first:  wsl --install  (then reopen).");
        if (!wsl) { try { Process.Start("https://docs.opensaas.sh/start/getting-started/"); } catch { } return; }
        if (MessageBox.Show("Install the Wasp CLI inside WSL now?\n\nRuns:  curl -sSL https://get.wasp.sh/installer.sh | sh", "Hydra", MessageBoxButtons.OKCancel, MessageBoxIcon.Question) != DialogResult.OK) return;
        try
        {
            var psi = new ProcessStartInfo("wsl.exe", "bash -lic \"curl -sSL https://get.wasp.sh/installer.sh | sh\"") { UseShellExecute = true };
            Process.Start(psi);
            SaasLog("Launched the Wasp installer in WSL. When it finishes, reopen and retry step 1.");
        }
        catch (Exception ex) { SaasLog("Install failed: " + ex.Message); }
    }

    void SaasCreate()
    {
        string parent = (saasFolder.Text ?? "").Trim();
        string name = (saasName.Text ?? "").Trim();
        if (name.Length == 0 || parent.Length == 0 || !Directory.Exists(parent)) { MessageBox.Show("Set a valid parent folder and app name first.", "Hydra"); return; }
        if (Directory.Exists(SaasAppDir())) { MessageBox.Show("That app folder already exists:\n" + SaasAppDir() + "\n\nPick a new name or delete it first.", "Hydra"); return; }
        bool haveWasp = OnPath("wasp.exe") || OnPath("wasp");
        bool wsl = OnPath("wsl.exe");
        if (!haveWasp && !wsl) { SaasCheckWasp(); return; }
        if (MessageBox.Show("Create a new Open SaaS app here?\n\n" + SaasAppDir() + "\n\nRuns 'wasp new " + name + " -t saas' — scaffolds the Open SaaS template (" + SaasTemplateRepo + ").", "Hydra", MessageBoxButtons.OKCancel, MessageBoxIcon.Question) != DialogResult.OK) return;
        saasStatus.Text = "Creating app with Wasp… a terminal will open; follow any prompts.";
        try
        {
            ProcessStartInfo psi;
            string inner = "wasp new " + name + " -t saas";
            if (haveWasp)
                psi = new ProcessStartInfo("cmd.exe", "/k cd /d \"" + parent + "\" && " + inner) { UseShellExecute = true };
            else
                psi = new ProcessStartInfo("wsl.exe", "bash -lic \"cd '" + ToWslPath(parent) + "' && " + inner + "; exec bash\"") { UseShellExecute = true };
            Process.Start(psi);
            SaasLog("Scaffolding started. When the terminal shows it's done, run step 3.");
        }
        catch (Exception ex) { SaasLog("Create failed: " + ex.Message); }
    }

    static string ToWslPath(string win)
    {
        try { string p = win.Replace("\\", "/"); if (p.Length > 1 && p[1] == ':') p = "/mnt/" + char.ToLower(p[0]) + p.Substring(2); return p; }
        catch { return win; }
    }

    static string PlaybookDoc()
    {
        return @"# Production Playbook — fastest correct sequence to a live SaaS

Battle-tested order. Each phase unblocks the next; account/authorization
steps come FIRST because they are the only steps that ever block for hours.
Keys can trickle in later — the codebase must no-op gracefully when a key
is missing (a feature without its key logs to console instead of failing).

## Phase 0 — Accounts & authorizations (do these before writing code)
These block everything downstream and need the human. Fire them all at once:
1. GitHub CLI: `gh auth login`, then IMMEDIATELY `gh auth refresh -h github.com -s workflow`
   (without the workflow scope, the FIRST push containing .github/workflows/ is rejected —
   this bit us in production; the default token never has it).
2. Firebase: `firebase login:ci` in a REAL terminal (never works in non-TTY shells) →
   store the token. It can headlessly: create projects, create web apps, fetch sdkconfig,
   deploy hosting. It canNOT enable Auth (see Phase 4).
3. Fly.io (if server hosting): `fly auth login` + card. Then set `send_metrics: false`
   in ~/.fly/config.yml or its stdout warnings corrupt wasp's JSON parsing.
4. AI: at minimum a free Groq key (console.groq.com/keys) — free tier serves real traffic.
5. Payments: create the Lemon Squeezy store NOW (self-serve, no approval gate) if
   international; Moyasar if KSA-local-only. Seller verification runs in the background
   while you build.
6. Store every token/key in Hydra → Settings → Access & API keys — they inject
   into every terminal and every future project reuses them.

## Phase 1 — Scaffold (goal: `wasp start` green in 15 minutes)
- `wasp new <name> -t saas` (Open SaaS is the mandatory base). If the target folder
  already has spec .md files, scaffold in a temp dir and move contents in.
- Machine quirks that WILL appear: root-owned npm cache → `npm config set cache <writable>`;
  root-owned global prefix → install CLIs with `--prefix ~/.npm-global`; Wasp 0.24+ needs
  Node 24; no Docker → `brew install postgresql@17 && brew services start postgresql@17`
  and put DATABASE_URL in .env.server.
- `wasp install && wasp db migrate-dev && wasp compile` must all pass before feature work.
- If prisma migrate-dev hits ""non-interactive not supported"": hand-write the migration SQL
  under migrations/<timestamp>_name/migration.sql and apply with
  `DATABASE_URL=... npx prisma migrate deploy --schema .wasp/out/db/schema.prisma`.

## Phase 2 — Build the product (architecture rules that held up)
- Firebase Auth means SKIPPING Wasp auth entirely: client Firebase Web SDK + an
  AuthContext; server = wasp `api()` REST endpoints with a `requireUser(req)` helper that
  verifies the Bearer ID token via firebase-admin and upserts the user by firebaseUid.
  This REST surface doubles as the public API (X-Api-Key auth) for Zapier/Make.
- Dev fallback: accept `dev:<email>` bearer tokens when NODE_ENV=development — and keep
  accepting them even after Firebase gets configured, or local testing dies later.
- firebase-admin verifies ID tokens with ONLY a project id (initializeApp({projectId})) —
  the service-account JSON is needed only for extras (Google Sheets etc.).
- Wasp api() handler gotchas: signature must accept a 3rd context arg
  `(req, res, _context?: unknown)`; cast `String(req.params.id)` (its string|string[] type
  poisons Prisma query inference with baffling errors); webhooks that verify HMAC over the
  raw body need `middlewareConfigFn` replacing 'express.json' with
  `express.json({ verify: (req,_res,buf) => { req.rawBody = buf } })`.
- CORS PREFLIGHT (cost us a full debugging cycle — do this from the start): Wasp attaches
  its cors middleware PER-ROUTE by the route's HTTP method, so a browser OPTIONS preflight
  matches NO route and returns without Access-Control-Allow-Origin — blocking EVERY authed
  browser call (any request with an Authorization or JSON content-type header triggers a
  preflight). It is invisible to curl/server-to-server tests (they send no preflight), so
  it only shows up in a real browser. Fix: add ONE `apiNamespace(""/api"", { middlewareConfigFn })`
  in a spec file (a passthrough `(c)=>c` is enough) — apiNamespace mounts via router.use,
  which DOES match OPTIONS. Verify with `curl -X OPTIONS <server>/api/me -H ""Origin: <client>""
  -H ""Access-Control-Request-Method: GET"" -H ""Access-Control-Request-Headers: authorization""`
  → expect 204 + access-control-allow-origin. Test in an actual browser before calling auth done.
- IDENTITY CONFLICT (unique email vs firebaseUid upsert): mirror users keyed by firebaseUid,
  but User.email is unique. If the same person signs in under a NEW uid while a row already
  holds their email (switched Google↔password, or a leftover test row), a plain
  `upsert({where:{firebaseUid}})` throws P2002 on email → /api/me 500s → the app looks
  totally broken (no login, no admin). requireUser must: find by uid → else find by email
  and CLAIM that row (update its firebaseUid) → else create. Never leave orphaned auth rows
  from test accounts; deleting the Firebase user does NOT delete the mirrored DB row.
- ADMIN PANEL from day one (every SaaS needs it): an admin-only /admin page gated by an
  `isAdmin` User flag (granted when the email is in ADMIN_EMAILS on sign-in — set that Fly
  secret BEFORE first admin login). Include: business KPIs (MRR/ARR, subscribers, trials,
  trial→paid, signups, past-due), a support INBOX reading the contact-form table (reply
  emails the customer + marks handled), and a user directory with per-user detail + controls
  (grant/revoke admin — guard against self-lockout, change plan, reset usage). Every admin
  endpoint calls requireAdmin; verify a non-admin token gets 403.
- Postgres JSONB does NOT preserve key order — any content-hash/diff over stored JSON must
  hash SORTED entries or every reread looks changed.
- Prerendered routes run your components in NODE at build time: any touch of
  localStorage / window / document outside useEffect (including useState INITIALIZERS)
  throws ""ReferenceError: localStorage is not defined"" and kills the CI build. Guard with
  `typeof window === ""undefined""` and move browser reads into useEffect. Always run the
  production client build locally before pushing UI that touches browser APIs.
- Entitlement lives in the DB, flipped ONLY by verified webhooks. Never trust the
  checkout redirect. Idempotency table for webhook event ids.
- Background jobs (pg-boss) need an always-on process — see Phase 3 hosting choice.

## Phase 3 — Deploy the skeleton EARLY (before the product is finished)
A live URL on day one surfaces CI/hosting problems while they are cheap.
- Client → Firebase Hosting: `firebase projects:create <id>`, `firebase apps:create WEB`,
  `firebase apps:sdkconfig WEB <appId>` (all headless with the CI token). Build with
  `wasp build` then `npx vite build` in app/ — output lands in
  `app/.wasp/out/web-app/build`; copy to the hosting public dir (""dist"").
  The client build hard-fails without REACT_APP_API_URL in env.
- CI (GitHub Actions): Node 24, PIN the wasp CLI (`npm i -g @wasp.sh/wasp-cli@<local
  version>`), deploy with `npx firebase-tools deploy --only hosting --non-interactive
  --token ""$FIREBASE_TOKEN""` (no service account needed).
- Server → Fly.io (default: always-on for cron jobs, cheapest at ~$5-10/mo, native
  `wasp deploy fly launch <name> <region>`; fra is closest to KSA). Known failure modes:
  the launch dies on a ""Press any key"" prompt after postgres attach in non-TTY shells —
  resume with `yes """" | wasp deploy fly deploy`; later server-only redeploys are
  `wasp build && fly deploy .wasp/out --config ""$PWD/fly-server.toml"" -a <name>-server
  --remote-only`. Verify fly-server.toml has `min_machines_running = 1` (pg-boss cron
  dies on scale-to-zero — this is also why Cloud Run is the WRONG host for this stack).
- Server secrets BEFORE first boot: WASP_WEB_CLIENT_URL (CORS — the Firebase Hosting URL),
  WASP_SERVER_URL, APP_URL, FIREBASE_PROJECT_ID. Set with `fly secrets set --stage`.
- Wire them together: set repo secret REACT_APP_API_URL=https://<name>-server.fly.dev,
  push, verify the live bundle references the server and an OPTIONS preflight from the
  client origin returns 200. If wasp also deployed a redundant fly client app, destroy it.

## Phase 4 — Firebase Auth enablement (the 2-click wall)
Free-tier Auth CANNOT be enabled headlessly: config PATCH 404s until Auth exists, and
identityPlatform:initializeAuth demands GCP billing. Ask the user for exactly 2 clicks:
console → Authentication → ""Get started"", then Google provider → Enable + support email.
After that, flip Email/Password via API: exchange the CI token for an access token
(oauth2.googleapis.com/token with firebase-tools' public client id/secret), then
`PATCH .../admin/v2/projects/<id>/config?updateMask=signIn.email`. Verify by creating and
deleting a real user via accounts:signUp with the web API key. Apple sign-in needs a paid
Apple Developer account — ship without it.

## Phase 5 — Payments (decision tree, learned the hard way)
- International customers matter → **Lemon Squeezy** (merchant of record): self-serve
  store, live in days, handles global sales tax, cards + PayPal + Apple/Google Pay.
  Integration: hosted checkout via POST /v1/checkouts (pass custom user_id), webhook with
  X-Signature HMAC over the RAW body syncing subscription_* events into the DB, customer
  portal URL from the subscription for card updates, cancel/resume via the LS API.
  EXCLUDE MoR-managed users from any local renewal cron — the MoR owns their recurrence.
  Before shipping the webhook, drive the WHOLE lifecycle locally with hand-signed
  payloads (created → payment_failed → cancelled → expired → duplicate replay): a
  20-line script catches mapping bugs that only surface with real subscribers.
- KSA-local only (mada/STC Pay) → **Moyasar** (fastest onboarding, amounts in HALALAS ×100)
  or Tap (amounts in MAJOR units — the two are opposite; read the spec, not your memory).
  Tap approval takes weeks — never put it on the critical path.
- Stripe is NOT available to KSA-domiciled businesses (only via a foreign entity).
- Hybrid pattern: MoR primary + local gateway later; keep both behind one /api/checkout.
- DISPLAY CURRENCY = the MoR's currency (LS bills in USD and localizes at checkout), which
  is usually NOT the local currency you first hardcoded. Keep ONE canonical `priceUsd` (or
  whatever the processor charges) in a shared plans module; the dormant local gateway
  converts at charge time. Sweeping SAR→USD across UI + emails + analytics after the fact
  is tedious — pick the processor's currency from the start.
- When no processor key is set yet, /api/checkout must return a clean 4xx (""payments not
  live yet""), never a stack trace mentioning a specific unconfigured gateway.

## Phase 6 — Custom domain: Namecheap → Firebase Hosting (proven ~40 min end to end)
Nearly everything is HEADLESS via the Hosting REST API — the console is never needed.
The only human steps are buying the domain and pasting 3 DNS records.
1. Buy: namecheap.com → search the name → .com/.ai/.io → enable the free Domain Privacy
   (WhoisGuard) → checkout, skip every upsell. Domain is usable in minutes.
2. Register the domain with Hosting via API (access token minted from the CI refresh
   token — NOTE: those access tokens expire in ~1h, re-mint per session, never cache):
   - apex: `POST https://firebasehosting.googleapis.com/v1beta1/projects/<p>/sites/<s>/customDomains?customDomainId=yourdomain.com` body `{""redirectTarget"":""""}`
   - www:  same endpoint, `customDomainId=www.yourdomain.com`, body `{""redirectTarget"":""yourdomain.com""}` (301 to apex)
   - `GET .../customDomains/yourdomain.com` → `requiredDnsUpdates.desired[].records[]`
     gives the EXACT records. Current Firebase infra wants just:
     `TXT @ hosting-site=<site-id>`, `A @ 199.36.158.100`, `CNAME www <site>.web.app`.
3. User pastes those 3 rows in Namecheap → Domain List → Manage → Advanced DNS.
   DELETE Namecheap's default parking CNAME/URL-redirect records first — they shadow yours.
4. Poll (all observable, no console): `dig` until the A + TXT resolve (Namecheap ≈ minutes),
   then GET the customDomain until `hostState: HOST_ACTIVE` (A seen) and
   `ownershipState: OWNERSHIP_ACTIVE` (TXT verified). Cert: it will sit at
   `cert.type: TEMPORARY, state: CERT_PROPAGATING` while ALREADY serving real TLS
   (Google Trust Services) — the site is live at this point; do NOT wait for CERT_ACTIVE,
   the dedicated cert swaps in on its own.
5. THE STEPS EVERYONE FORGETS — update every reference to the old .web.app URL:
   - Auth authorized domains, headless: `PATCH identitytoolkit .../config?updateMask=authorizedDomains`
     appending the new apex + www (sign-in silently fails on them otherwise).
   - Fly server secrets: WASP_WEB_CLIENT_URL + APP_URL → https://yourdomain.com (CORS
     breaks otherwise); `fly secrets set` restarts machines; verify with an OPTIONS
     preflight from the new Origin (expect 200).
   - Repo secret REACT_APP_API_URL stays the server URL; if the server gets its own
     subdomain: `fly certs add api.yourdomain.com -a <name>-server` + Namecheap
     `CNAME api → <name>-server.fly.dev`, then update REACT_APP_API_URL and push.
   - Payment provider store/redirect URLs, GA4 stream URL, sitemap/OG urls.
   - Finish with a real e2e from the new origin: signup → authed API call → delete user.

## Phase 6b — Analytics & monitoring implementation (per ANALYTICS.md, proven pattern)
- Client: `src/analytics/ga.ts` — consent state in localStorage, gtag injected ONLY after
  Accept, `trackEvent()` no-ops before consent/without a measurement id, plus SPA
  `trackPageView` on route change. A ~40-line ConsentBanner component beats a cookie lib.
- Wire funnel events at the SUCCESS points, not the clicks: sign_up/login (with method)
  right before the post-auth redirect, trial_started after the API confirms,
  begin_checkout before handing off to the processor, one event per core action.
- Server: `src/analytics/mp.ts` — GA4 Measurement Protocol with a sha256(userId) client id.
  Fire `purchase` ONLY on the payment-success webhook event (money moved), never also on
  subscription_created — the two arrive in any order and double-count revenue.
- Health: `GET /api/health` runs `SELECT 1` so ""up"" means serving, wired into
  `[[http_service.checks]]` in fly-server.toml — unhealthy machines self-restart.
- All of it ships with EMPTY env ids and no-ops gracefully; the user creates the GA4
  property (property + web stream + MP api_secret = 3 minutes) whenever ready.

## Phase 7 — Email: inbound + outbound (two separate jobs, both easy to get wrong)
INBOUND (support@yourdomain — customers reach you): Namecheap → Domain → Manage → Email
Forwarding (free): add `support` → your inbox. It auto-adds root MX (eforward1-5.registrar-
servers.com). Verify `dig MX yourdomain` shows them.
OUTBOUND (send receipts/replies): Resend → add sending domain → it lists DKIM (TXT) + an SPF
TXT + an MX, all on a `send.` subdomain. Add them, click Verify (poll the Resend domains API
for status:""verified""; DKIM alone won't flip it — the send MX is required). Then set
RESEND_API_KEY + EMAIL_FROM=support@yourdomain and send a live test.
- THE CONFLICT (cost us a broken inbox): Namecheap ""Email Forwarding"" and ""Custom MX"" are
  MUTUALLY EXCLUSIVE in the Mail Settings dropdown. Resend's send-subdomain MX needs Custom
  MX, and switching to it WIPES the eforward forwarding records — silently killing inbound
  support mail. Fix: under Custom MX, re-add ALL of it by hand — the 5 eforward MX on host
  `@` (restores forwarding) PLUS the Resend MX on host `send`. Verify BOTH directions after:
  `dig MX yourdomain` (eforward present) and `dig MX send.yourdomain` (Resend present).
- RESILIENT SENDS: the contact form / any user-facing action must STORE first and treat the
  email as best-effort (try/catch, never 500 on a send failure — the domain may still be
  verifying). But an admin ""reply"" should check Resend's returned `error` and NOT mark the
  ticket resolved if the send actually failed. Until RESEND_API_KEY exists, log to console.
- Transactional and broadcast stay separate streams; every broadcast carries
  List-Unsubscribe + a one-click unsubscribe endpoint.

## Phase 8 — Production acceptance (nothing ships without this)
- Real end-to-end on PRODUCTION: create a real user (Firebase accounts:signUp with the
  web API key), exercise the core product action via the live API, confirm the DB row,
  then delete the test user via accounts:delete.
- Webhooks: unsigned POST → 401; signed replay of the same event → duplicate:true.
- CI: push to main → green run → live site actually updated (grep the deployed bundle).
- Record the project state (URLs, accounts, stubbed keys, quirks) in memory/docs so the
  next session resumes instead of rediscovering.

## Skills to load, per phase (MANDATORY — load BEFORE the phase's work, not after)
The installed builder skills encode taste and guardrails this playbook depends on.
Skipping them produces generic output that later needs redoing — slower, not faster.
- **Whole build, always on**: `karpathy-guidelines` (surgical changes, no
  overengineering, verifiable success criteria) + `full-output-enforcement`
  (no stubs, no placeholders, complete files only).
- **Phase 2 UI work**: `design-taste-frontend` (the anti-slop design system: dial
  calibration, banned AI-tells, layout discipline) — load it BEFORE writing the first
  component, declare the design read, and run its pre-flight check before shipping
  pages. Complement with `high-end-visual-design` / `gpt-taste` when the brief wants
  premium polish, `imagegen-frontend-web` + `image-to-code` when real visuals are needed.
- **All user-facing COPY (landing, about, emails, empty states)**: `stop-slop` — strip
  the AI writing tells (em-dashes are banned everywhere anyway, hedging, ""delve"",
  mirrored parallelisms). Copy reads like a person wrote it or it gets rewritten.
- **Phase 2 AI features**: `ai-integration` (the router ladder is its reference impl).
- **Phase 3 deploys**: `cloud-deployment`.
- **Phase 5 billing + email**: `subscription-billing` (four pillars, webhook rules,
  KSA specifics, deliverability).
- **Before any commit of nontrivial product code**: run `verify` (drive the changed
  flow end-to-end) and a `/code-review` pass on the diff.

## Human-blocking steps — collect these ALL at the start (they gate, code doesn't)
Everything a human must click sits behind an account or a payment. Ask for them in ONE
batch up front, build while they trickle in, and make every feature no-op gracefully
until its key/value lands. The full list for a Firebase+Fly+LS+Resend SaaS:
- `gh auth refresh -s workflow`, `firebase login:ci`, `fly auth login` (+card).
- Firebase console: Authentication → Get started + enable Google (the 2 clicks).
- Payments: create the LS store + 2 subscription products (products are DASHBOARD-ONLY;
  the API can't create them). Then 5 values: API key, Store ID, webhook secret, and the
  2 monthly variant IDs (the rest — store lookup, webhook creation, variant discovery — I
  do via the LS API from just the API key).
- GA4: create property + web stream + a Measurement Protocol secret (Google gates account
  creation to the owner's browser; my token can't).
- Domain: buy it; add DNS rows I hand you; set up email forwarding + Resend records.
Each of these is the ONLY thing that ever blocks for real time. Request early, in bulk.

## Sequencing summary (the fast path)
Phase 0 all-at-once → 1 scaffold → 3 skeleton deploy (yes, before the product) →
2 product build (incl. admin panel + contact/support form) → 4 auth clicks (user, 2 min) →
5 payments → 6 domain → 6b monitoring → 7 email (inbound + outbound) → 8 accept.
Human-blocking steps get requested EARLY and in BATCHES — never serialize a build behind
a waiting human.
Reference timings from a real run (Page Byte, 2026-07): scaffold→compiling ~15 min,
skeleton live on Hosting same hour, Fly server + Postgres ~20 min, Auth enablement
2 clicks + 5 min, LS integration incl. lifecycle tests ~1h, domain purchase→live TLS
~40 min, GA4+monitoring ~45 min, admin panel + support inbox ~45 min. Same-day ship.
The debugging cycles that DIDN'T need to happen (and now shouldn't): CORS preflight,
the unique-email identity 500, prerender localStorage crash, forwarding-vs-CustomMX
inbox wipe. All are pre-empted above — read Phase 2 and Phase 7 before writing code.
";
    }


    string BuildVisionDoc()
    {
        var sb = new StringBuilder();
        sb.AppendLine("# Product Vision — " + (saasName.Text ?? "").Trim());
        sb.AppendLine();
        sb.AppendLine("## One-liner");
        sb.AppendLine((saasPitch.Text ?? "").Trim());
        sb.AppendLine();
        sb.AppendLine("## Core features / pages");
        foreach (var l in (saasFeatures.Text ?? "").Replace("\r", "").Split('\n'))
            if (l.Trim().Length > 0) sb.AppendLine("- " + l.Trim());
        sb.AppendLine();
        sb.AppendLine("## Stack decisions");
        sb.AppendLine("- Auth: " + (saasAuth.SelectedItem ?? ""));
        string authSel = (saasAuth.SelectedItem ?? "").ToString();
        if (authSel.StartsWith("Firebase"))
        {
            sb.AppendLine("  (Integrated provider: **Firebase Authentication** — email/password + Google + Apple via the Firebase Web SDK. On first sign-in, mirror the user into the app's own User table keyed by the Firebase UID; protect every server route by verifying the Firebase ID token with firebase-admin. Put the Firebase web config in client env vars and the service-account JSON in FIREBASE_SERVICE_ACCOUNT, never committed.)");
            sb.AppendLine("  (Enablement playbook — learned the hard way, follow it instead of rediscovering:");
            sb.AppendLine("   - What WORKS headless with a `firebase login:ci` token: `firebase projects:create`, `firebase apps:create WEB`, `firebase apps:sdkconfig WEB <appId>` (gives apiKey/authDomain/projectId/appId for the client env), and `firebase deploy --only hosting --token \"$FIREBASE_TOKEN\"`.");
            sb.AppendLine("   - What does NOT work headless on a free project: the initial Auth enablement. `PATCH admin/v2/.../config` returns 404 CONFIGURATION_NOT_FOUND until Auth exists, and `identityPlatform:initializeAuth` returns 400 BILLING_NOT_ENABLED (that API is the paid Identity Platform). The free classic Auth config is created ONLY by the console's \"Get started\" button. The Google provider also needs the console (it auto-creates the OAuth client; the raw API demands one by hand).");
            sb.AppendLine("   - So ask the user for exactly 2 clicks: console → Authentication → \"Get started\", then Google provider → Enable + support email → Save. AFTER that, Email/Password CAN be flipped via API: exchange the CI token for an access token (oauth2.googleapis.com/token, firebase-tools' public client id/secret, grant_type=refresh_token), then `PATCH https://identitytoolkit.googleapis.com/admin/v2/projects/<id>/config?updateMask=signIn.email` with {\"signIn\":{\"email\":{\"enabled\":true,\"passwordRequired\":true}}}. Verify authorized domains include the Hosting domain.");
            sb.AppendLine("   - Dev fallback so the app works before any of this: accept `dev:<email>` bearer tokens in development only; firebase-admin verifies real ID tokens with just FIREBASE_PROJECT_ID (no service account needed) — the service-account JSON is only required for extras like Google Sheets access.");
            sb.AppendLine("   - Apple sign-in requires a paid Apple Developer account — ship without it, add later.)");
        }
        else if (authSel.StartsWith("Supabase"))
            sb.AppendLine("  (Integrated provider: **Supabase Auth** — email/password + social via supabase-js. Mirror users into the app's User table keyed by the Supabase user id; verify the Supabase JWT server-side with SUPABASE_JWT_SECRET. Keys: SUPABASE_URL + SUPABASE_ANON_KEY client-side, SUPABASE_SERVICE_ROLE_KEY server-only.)");
        else if (authSel.StartsWith("Clerk"))
            sb.AppendLine("  (Integrated provider: **Clerk** — use its drop-in <SignIn/>/<UserButton/> components for the whole auth UI. Mirror users into the app's User table via the Clerk webhook (user.created); protect API routes with Clerk's server middleware. Keys: Clerk publishable key client-side, CLERK_SECRET_KEY server-only.)");
        sb.AppendLine("- Payments: " + (saasPay.SelectedItem ?? ""));
        if (PaymentKey() != "none")
            sb.AppendLine("  (see PAYMENTS.md in this folder for the verified integration spec + .env.server keys)");
        sb.AppendLine("- AI layer: " + (saasAI.SelectedItem ?? ""));
        if (AiEnabled())
            sb.AppendLine("  (see AI.md — our integrated multi-provider router with a best→cheapest priority ladder over OpenRouter + Groq + free commercial providers; wire ALL AI features through it)");
        sb.AppendLine("- Analytics: Google Analytics 4 — MANDATORY for every use case");
        sb.AppendLine("  (see ANALYTICS.md — consent-gated gtag via the Open SaaS cookie-consent banner, required events, and the admin-dashboard stats job)");
        sb.AppendLine("- Base template: Open SaaS (Wasp + React + Node + Prisma) — " + SaasTemplateRepo);
        sb.AppendLine("  (MANDATORY for every use case: if this folder is not an Open SaaS app yet, scaffold it with `wasp new -t saas` before anything else; never substitute another starter)");
        sb.AppendLine();
        sb.AppendLine("## Build instructions for Claude");
        sb.AppendLine("You are working inside a freshly scaffolded Open SaaS app. Implement the vision above:");
        sb.AppendLine("1. Read the Open SaaS structure (main.wasp / *.wasp, src/, schema.prisma).");
        sb.AppendLine("2. Configure auth to match the choice above; remove unused providers.");
        sb.AppendLine("3. Wire the chosen payment processor. If PAYMENTS.md exists, follow it EXACTLY (esp. the amount-unit rule) and stub the listed .env.server keys with clear TODOs.");
        sb.AppendLine("4. Build each feature/page listed, updating the Wasp config, routes, entities, and UI.");
        sb.AppendLine("5. Wire Google Analytics 4 exactly as ANALYTICS.md describes (consent-gated gtag, required events, admin stats job; env ids stubbed).");
        sb.AppendLine("6. Keep it runnable at every step (wasp start). Explain each change briefly.");
        sb.AppendLine("7. Do NOT commit real secrets. Ask the user before any destructive or paid action.");
        return sb.ToString();
    }

    string PaymentKey()
    {
        string s = (saasPay.SelectedItem ?? "").ToString();
        if (s.StartsWith("Tap")) return "tap";
        if (s.StartsWith("Moyasar")) return "moyasar";
        if (s.StartsWith("Stripe")) return "stripe";
        if (s.StartsWith("Lemon")) return "lemonsqueezy";
        if (s.StartsWith("Polar")) return "polar";
        return "none";
    }

    // ---- AI layer: our own integrated multi-provider router (OpenRouter + Groq + free) ----
    bool AiEnabled() { return !(saasAI.SelectedItem ?? "").ToString().StartsWith("None"); }

    string AiKey()
    {
        string s = (saasAI.SelectedItem ?? "").ToString();
        if (s.StartsWith("OpenRouter")) return "openrouter";
        if (s.StartsWith("Groq")) return "groq";
        if (s.StartsWith("BYOK")) return "byok";
        return "smart";
    }

    string AiSpec()
    {
        string strat = AiKey();
        var sb = new StringBuilder();
        sb.AppendLine("# AI layer — " + (saasName.Text ?? "").Trim());
        sb.AppendLine();
        sb.AppendLine("Strategy: **" + (saasAI.SelectedItem ?? "") + "**. This app talks to ONE internal router (`src/server/ai/router.ts`)");
        sb.AppendLine("that exposes an OpenAI-compatible `chat()` call and automatically falls back down a");
        sb.AppendLine("performance-ranked ladder when a model is rate-limited or fails. Every provider below");
        sb.AppendLine("permits commercial use within its published free rate limits — no ToS games, no personal");
        sb.AppendLine("subscription accounts. Use the bundled `ai-integration` skill for the reference implementation.");
        sb.AppendLine();
        sb.AppendLine("## Priority ladder — best model first, cheapest fallback last");
        sb.AppendLine("The router tries these in order and drops to the next on 429 / 5xx / timeout:");
        sb.AppendLine();
        sb.AppendLine("| # | Model | Provider | Cost | Notes |");
        sb.AppendLine("|---|-------|----------|------|-------|");
        sb.AppendLine("| 1 | `openai/gpt-4o` / `anthropic/claude-3.5-sonnet` | OpenRouter (paid) | ~$2.5–3/M | Frontier quality — hardest tasks / paid tiers |");
        sb.AppendLine("| 2 | `google/gemini-2.5-pro` | OpenRouter or Gemini API | cheap paid | Big context, strong reasoning |");
        sb.AppendLine("| 3 | `deepseek/deepseek-r1` | OpenRouter | ~$0.5/M | Best cheap reasoning model |");
        sb.AppendLine("| 4 | `llama-3.3-70b-versatile` | **Groq** | **free** | Fast + free, commercial OK — great default |");
        sb.AppendLine("| 5 | `deepseek/deepseek-chat:free` | **OpenRouter `:free`** | **free** | Strong general model, free tier |");
        sb.AppendLine("| 6 | `qwen/qwen-2.5-72b-instruct:free` | **OpenRouter `:free`** | **free** | Strong multilingual (good Arabic) |");
        sb.AppendLine("| 7 | `gemini-2.0-flash` | **Google AI Studio** | **free** | Fast, generous free tier, commercial OK |");
        sb.AppendLine("| 8 | `llama-3.1-8b-instant` | **Groq** | **free** | Lowest latency — cheap/simple calls |");
        sb.AppendLine("| 9 | `llama-3.3-70b` | **Cerebras** | **free** | Fastest inference, free tier |");
        sb.AppendLine("| 10 | `@cf/meta/llama-3.1-8b-instruct` | **Cloudflare Workers AI** | **free** | Last-resort always-on fallback |");
        sb.AppendLine();
        if (strat == "openrouter")
        {
            sb.AppendLine("### Active order for this build (OpenRouter only)");
            sb.AppendLine("Route everything through OpenRouter with a single `OPENROUTER_API_KEY`. Order: paid frontier for premium tiers, then `:free` models (`deepseek/deepseek-chat:free`, `meta-llama/llama-3.3-70b-instruct:free`, `qwen/qwen-2.5-72b-instruct:free`) for the free tier. One key, 300+ models, built-in fallback via the `models` array.");
        }
        else if (strat == "groq")
        {
            sb.AppendLine("### Active order for this build (Groq only)");
            sb.AppendLine("Route through Groq with `GROQ_API_KEY`: `llama-3.3-70b-versatile` (default), `qwen-2.5-32b`, `llama-3.1-8b-instant` (fast path), `deepseek-r1-distill-llama-70b` (reasoning). Free tier, commercial OK, fastest tokens/sec available.");
        }
        else if (strat == "byok")
        {
            sb.AppendLine("### Active order for this build (BYOK — customer brings the key)");
            sb.AppendLine("Do NOT ship any provider key. In account settings let each customer paste their own OpenRouter/OpenAI/Groq/Anthropic key (store encrypted at rest, AES-256-GCM). All AI cost is theirs — $0 AI for you and fully within every provider's ToS. Fall back to the free ladder ONLY if you (the operator) provide a shared key for a limited free tier.");
        }
        else
        {
            sb.AppendLine("### Active order for this build (Smart fallback — recommended)");
            sb.AppendLine("Free tier serves users on the free ladder (rows 4–10, $0). Paid tiers unlock the frontier rows (1–3), billed per token so revenue covers cost. The router picks the highest-priority model whose key is present and whose budget the caller's plan allows, then falls back automatically.");
        }
        sb.AppendLine();
        sb.AppendLine("## Provider signup (all commercial-use-OK free tiers)");
        sb.AppendLine("- **OpenRouter** — https://openrouter.ai/keys · one key → 300+ models incl. many `:free`");
        sb.AppendLine("- **Groq** — https://console.groq.com/keys · fastest free inference");
        sb.AppendLine("- **Google AI Studio (Gemini)** — https://aistudio.google.com/apikey · generous free tier");
        sb.AppendLine("- **Cerebras** — https://cloud.cerebras.ai · fast free tier");
        sb.AppendLine("- **Cloudflare Workers AI** — https://dash.cloudflare.com · free neurons/day, always-on fallback");
        sb.AppendLine();
        sb.AppendLine("Set only the keys for the providers you use (see `.env.ai.example`). Missing keys are skipped, not fatal.");
        sb.AppendLine();
        sb.AppendLine("## Drop-in router (src/server/ai/router.ts)");
        sb.AppendLine("Because Groq, OpenRouter, Cerebras and Gemini (OpenAI-compat endpoint) all speak the OpenAI API, one client covers them all:");
        sb.AppendLine();
        sb.AppendLine("```ts");
        sb.AppendLine(AiRouterCode());
        sb.AppendLine("```");
        sb.AppendLine();
        sb.AppendLine("Usage: `const answer = await aiChat([{ role: 'user', content: prompt }])`. It returns the first successful completion and logs which provider/model served it. Never expose keys client-side — all AI calls go through your server.");
        sb.AppendLine();
        sb.AppendLine("## Rules");
        sb.AppendLine("- Keys live in `.env.server` only; never commit them, never send them to the browser.");
        sb.AppendLine("- Respect each provider's rate limits; the fallback handles 429s gracefully.");
        sb.AppendLine("- Meter usage per user/plan so a free user can't drain your paid tiers (tie into SUBSCRIPTIONS.md credits).");
        sb.AppendLine("- Keep the ladder in ONE config array so you can re-rank models as new ones ship.");
        return sb.ToString();
    }

    string AiRouterCode()
    {
        var sb = new StringBuilder();
        sb.AppendLine("import OpenAI from \"openai\";");
        sb.AppendLine();
        sb.AppendLine("// Priority ladder: best model first, free/cheap fallbacks last. Re-rank freely.");
        sb.AppendLine("// Each entry names the provider base URL + the env var holding its key.");
        sb.AppendLine("type Rung = { provider: string; model: string; baseURL: string; keyEnv: string };");
        sb.AppendLine("const LADDER: Rung[] = [");
        sb.AppendLine("  // frontier (paid — premium tiers)");
        sb.AppendLine("  { provider: \"openrouter\", model: \"openai/gpt-4o\",                    baseURL: \"https://openrouter.ai/api/v1\", keyEnv: \"OPENROUTER_API_KEY\" },");
        sb.AppendLine("  { provider: \"openrouter\", model: \"google/gemini-2.5-pro\",           baseURL: \"https://openrouter.ai/api/v1\", keyEnv: \"OPENROUTER_API_KEY\" },");
        sb.AppendLine("  { provider: \"openrouter\", model: \"deepseek/deepseek-r1\",            baseURL: \"https://openrouter.ai/api/v1\", keyEnv: \"OPENROUTER_API_KEY\" },");
        sb.AppendLine("  // free, commercial-use OK");
        sb.AppendLine("  { provider: \"groq\",       model: \"llama-3.3-70b-versatile\",         baseURL: \"https://api.groq.com/openai/v1\", keyEnv: \"GROQ_API_KEY\" },");
        sb.AppendLine("  { provider: \"openrouter\", model: \"deepseek/deepseek-chat:free\",     baseURL: \"https://openrouter.ai/api/v1\", keyEnv: \"OPENROUTER_API_KEY\" },");
        sb.AppendLine("  { provider: \"openrouter\", model: \"qwen/qwen-2.5-72b-instruct:free\", baseURL: \"https://openrouter.ai/api/v1\", keyEnv: \"OPENROUTER_API_KEY\" },");
        sb.AppendLine("  { provider: \"gemini\",     model: \"gemini-2.0-flash\",                baseURL: \"https://generativelanguage.googleapis.com/v1beta/openai\", keyEnv: \"GEMINI_API_KEY\" },");
        sb.AppendLine("  { provider: \"groq\",       model: \"llama-3.1-8b-instant\",            baseURL: \"https://api.groq.com/openai/v1\", keyEnv: \"GROQ_API_KEY\" },");
        sb.AppendLine("  { provider: \"cerebras\",   model: \"llama-3.3-70b\",                   baseURL: \"https://api.cerebras.ai/v1\", keyEnv: \"CEREBRAS_API_KEY\" },");
        sb.AppendLine("];");
        sb.AppendLine();
        sb.AppendLine("export type ChatMsg = { role: \"system\" | \"user\" | \"assistant\"; content: string };");
        sb.AppendLine();
        sb.AppendLine("// Try each configured rung in order; fall through on rate-limit / 5xx / network error.");
        sb.AppendLine("export async function aiChat(messages: ChatMsg[], opts: { maxRung?: number } = {}) {");
        sb.AppendLine("  const rungs = LADDER.slice(0, opts.maxRung ?? LADDER.length).filter(r => process.env[r.keyEnv]);");
        sb.AppendLine("  if (!rungs.length) throw new Error(\"No AI provider keys configured — set at least one in .env.server\");");
        sb.AppendLine("  let lastErr: unknown;");
        sb.AppendLine("  for (const r of rungs) {");
        sb.AppendLine("    try {");
        sb.AppendLine("      const client = new OpenAI({ apiKey: process.env[r.keyEnv]!, baseURL: r.baseURL });");
        sb.AppendLine("      const res = await client.chat.completions.create({ model: r.model, messages });");
        sb.AppendLine("      console.log(`[ai] served by ${r.provider}:${r.model}`);");
        sb.AppendLine("      return { text: res.choices[0]?.message?.content ?? \"\", provider: r.provider, model: r.model };");
        sb.AppendLine("    } catch (e: any) {");
        sb.AppendLine("      const status = e?.status ?? e?.response?.status;");
        sb.AppendLine("      lastErr = e;");
        sb.AppendLine("      if (status && ![429, 500, 502, 503, 504].includes(status)) throw e; // real error → stop");
        sb.AppendLine("      console.warn(`[ai] ${r.provider}:${r.model} failed (${status ?? \"network\"}) → next`);");
        sb.AppendLine("    }");
        sb.AppendLine("  }");
        sb.AppendLine("  throw lastErr ?? new Error(\"All AI providers exhausted\");");
        sb.AppendLine("}");
        return sb.ToString();
    }

    string AiEnvExample()
    {
        var sb = new StringBuilder();
        sb.AppendLine("# AI provider keys — set only the ones you use; the router skips any that are missing.");
        sb.AppendLine("# All of these have commercial-use-OK free tiers. Keys are SERVER-ONLY — never expose to the browser.");
        sb.AppendLine("OPENROUTER_API_KEY=   # https://openrouter.ai/keys  (one key → 300+ models incl. :free)");
        sb.AppendLine("GROQ_API_KEY=         # https://console.groq.com/keys  (fastest free inference)");
        sb.AppendLine("GEMINI_API_KEY=       # https://aistudio.google.com/apikey  (generous free tier)");
        sb.AppendLine("CEREBRAS_API_KEY=     # https://cloud.cerebras.ai  (fast free tier)");
        sb.AppendLine("# CLOUDFLARE_ACCOUNT_ID / CLOUDFLARE_API_TOKEN for Workers AI last-resort fallback");
        return sb.ToString();
    }

    string PaymentDocsUrl(string key)
    {
        switch (key)
        {
            case "tap": return "https://developers.tap.company/";
            case "moyasar": return "https://docs.moyasar.com/";
            case "polar": return "https://docs.polar.sh/";
            default: return "https://docs.opensaas.sh/guides/payments-integration/";
        }
    }

    string[] PaymentEnvVars(string key)
    {
        switch (key)
        {
            case "tap": return new[] { "TAP_SECRET_KEY=sk_test_xxx", "TAP_PUBLISHABLE_KEY=pk_test_xxx" };
            case "moyasar": return new[] { "MOYASAR_SECRET_KEY=sk_test_xxx", "MOYASAR_PUBLISHABLE_KEY=pk_test_xxx" };
            case "stripe": return new[] { "STRIPE_API_KEY=sk_test_xxx", "STRIPE_WEBHOOK_SECRET=whsec_xxx" };
            case "lemonsqueezy": return new[] { "LEMONSQUEEZY_API_KEY=xxx", "LEMONSQUEEZY_WEBHOOK_SECRET=xxx" };
            case "polar": return new[] { "POLAR_ACCESS_TOKEN=xxx", "POLAR_WEBHOOK_SECRET=xxx" };
            default: return new string[0];
        }
    }

    // Verified integration facts (from developers.tap.company & docs.moyasar.com) so Claude
    // generates CORRECT code — especially the amount-unit gotcha, which is INVERTED between
    // ---- analytics: Google Analytics 4, mandatory for every use case ----
    string AnalyticsSpec()
    {
        var sb = new StringBuilder();
        sb.AppendLine("# Analytics — " + (saasName.Text ?? "").Trim());
        sb.AppendLine();
        sb.AppendLine("**Google Analytics 4 is REQUIRED for this app — every use case ships with it.** Open SaaS has first-class GA4 support (cookie-consent banner + admin-dashboard stats job); use it, do not hand-roll.");
        sb.AppendLine();
        sb.AppendLine("## 1. Create the GA4 property");
        sb.AppendLine("- analytics.google.com → Admin → Create property → add a **Web** data stream → copy the **Measurement ID** (`G-XXXXXXXXXX`).");
        sb.AppendLine();
        sb.AppendLine("## 2. Client tracking (built into Open SaaS)");
        sb.AppendLine("- Open SaaS ships a cookie-consent banner (vanilla-cookieconsent) that injects the gtag script ONLY after the visitor accepts — GDPR-safe by default. Keep that flow; never load gtag before consent.");
        sb.AppendLine("- Put the Measurement ID in the client env (`.env.client`): `REACT_APP_GOOGLE_ANALYTICS_ID=G-XXXXXXXXXX`.");
        sb.AppendLine("- Make sure the cookie-consent config (src/client/components/cookie-consent/Config.ts or equivalent) reads that same id.");
        sb.AppendLine();
        sb.AppendLine("## 3. Admin dashboard stats (server side)");
        sb.AppendLine("Open SaaS's daily stats job pulls GA metrics (page views, sources) into the admin dashboard via the **Google Analytics Data API**:");
        sb.AppendLine("- Google Cloud console: enable \"Google Analytics Data API\", create a service account, download its JSON key.");
        sb.AppendLine("- GA Admin → Property access management: add the service-account email as **Viewer**.");
        sb.AppendLine("- `.env.server` keys (stub with TODOs, never commit real values):");
        sb.AppendLine("  - `GOOGLE_ANALYTICS_CLIENT_EMAIL=service-account@project.iam.gserviceaccount.com`");
        sb.AppendLine("  - `GOOGLE_ANALYTICS_PRIVATE_KEY=` (the key, base64-encoded, per the Open SaaS docs)");
        sb.AppendLine("  - `GOOGLE_ANALYTICS_PROPERTY_ID=` (the NUMERIC property id, not the G-… id)");
        sb.AppendLine("- Keep the daily stats job enabled in main.wasp so the admin dashboard fills in.");
        sb.AppendLine();
        sb.AppendLine("## 4. Events that MUST be tracked (the full SaaS funnel)");
        sb.AppendLine("Add a tiny `trackEvent(name, params)` helper that no-ops until consent, then wire EVERY stage:");
        sb.AppendLine("- **Acquisition**: `page_view` (automatic), `cta_click` (which CTA, which section).");
        sb.AppendLine("- **Activation**: `sign_up` (method: email/google/apple), `login`, plus the product's FIRST \"aha\" action from VISION.md as `activation` — the metric that predicts retention.");
        sb.AppendLine("- **Revenue**: `begin_checkout` (plan), `trial_started` (plan), `purchase` (plan, value, currency — fire SERVER-SIDE from the payment webhook via the GA4 Measurement Protocol so ad blockers can't hide revenue), `subscription_renewed`, `subscription_cancelled` (plan, days_subscribed), `payment_failed`.");
        sb.AppendLine("- **Engagement**: one event per core feature action in VISION.md, plus `limit_reached` (which limit — the strongest upgrade signal there is) and `api_key_created`.");
        sb.AppendLine("- Mark `sign_up`, `trial_started`, and `purchase` as CONVERSIONS in GA4 Admin → Events.");
        sb.AppendLine();
        sb.AppendLine("## 5. Beyond GA4 — the full monitoring stack (all free tiers, all mandatory)");
        sb.AppendLine("A SaaS you can't observe is a SaaS you can't run. Wire ALL of these:");
        sb.AppendLine("- **Error monitoring — Sentry** (free tier): `@sentry/react` on the client (wrap the app, upload sourcemaps in CI) + `@sentry/node` on the server (capture in the API error handler and job failures). Env: `SENTRY_DSN` / `REACT_APP_SENTRY_DSN`, stubbed. Tag events with plan + release so paid-user bugs surface first.");
        sb.AppendLine("- **Uptime — Better Stack or UptimeRobot** (free): monitor the site AND the server health endpoint every 60s with alerts. Add `GET /api/health` returning `{status:\"ok\", db:true}` (touch the DB so it proves real health).");
        sb.AppendLine("- **Host-level checks**: Fly.io `[[http_service.checks]]` hitting /api/health so dead machines restart themselves; keep structured console.log JSON lines for greppability.");
        sb.AppendLine("- **Business KPI snapshot**: extend the daily stats job to compute and store MRR, active subscribers, trials in flight, trial→paid conversion %, churn, signups/day — the admin dashboard answers \"how is the business\" in one glance.");
        sb.AppendLine("- **Search Console**: verify the domain (DNS TXT), submit the sitemap — free SEO diagnostics and the only place Google reports indexing problems.");
        sb.AppendLine("- **Alerting rule**: uptime + payment-webhook failures page you; everything else is a weekly dashboard.");
        sb.AppendLine();
        sb.AppendLine("## Rules");
        sb.AppendLine("- Never block rendering on gtag; load async after consent.");
        sb.AppendLine("- No PII in event params (no emails, names, phone numbers).");
        sb.AppendLine("- Server-side revenue events use the GA4 Measurement Protocol (`GA4_API_SECRET` in .env.server, stubbed).");
        sb.AppendLine("- Verify with GA DebugView before launch; docs: https://docs.opensaas.sh/guides/analytics/");
        return sb.ToString();
    }

    string AnalyticsEnvExample()
    {
        return "# Google Analytics 4 — mandatory for every build. Never commit real values.\n"
            + "# Client (.env.client) — the web stream Measurement ID:\n"
            + "REACT_APP_GOOGLE_ANALYTICS_ID=G-XXXXXXXXXX\n"
            + "# Server (.env.server) — Google Analytics Data API service account (admin dashboard stats):\n"
            + "GOOGLE_ANALYTICS_CLIENT_EMAIL=service-account@project.iam.gserviceaccount.com\n"
            + "GOOGLE_ANALYTICS_PRIVATE_KEY=   # base64-encoded private key\n"
            + "GOOGLE_ANALYTICS_PROPERTY_ID=   # numeric property id (not the G-… id)\n"
            + "# Server-side revenue events (GA4 Measurement Protocol, from the payment webhook):\n"
            + "GA4_API_SECRET=\n"
            + "# Error monitoring (Sentry, free tier — client + server):\n"
            + "REACT_APP_SENTRY_DSN=\n"
            + "SENTRY_DSN=\n";
    }

    // the two Saudi gateways (Tap = decimal SAR, Moyasar = integer halalas).
    string PaymentSpec(string key)
    {
        var sb = new StringBuilder();
        if (key == "tap")
        {
            sb.AppendLine("# Payment integration — Tap Payments (KSA)");
            sb.AppendLine();
            sb.AppendLine("- API base: `https://api.tap.company/v2/`");
            sb.AppendLine("- Auth: HTTP header `Authorization: Bearer <secret_key>` (server-side only). Secret keys are `sk_test_…` / `sk_live_…`; publishable `pk_test_…` is for the web card SDK.");
            sb.AppendLine("- Create a charge: `POST /charges`. Required fields:");
            sb.AppendLine("  - `amount` — **DECIMAL in the currency unit, NOT minor units.** 10.00 SAR is sent as `10.00` (a `10`). Do NOT multiply by 100.");
            sb.AppendLine("  - `currency` — `\"SAR\"`");
            sb.AppendLine("  - `customer` — object with `first_name` and `email` (optional `phone: { country_code: 966, number: ... }`)");
            sb.AppendLine("  - `source` — object with `id`; use `\"src_all\"` to show all methods, or `src_card` / `src_mada` / `src_apple_pay`, or a tokenized card id from the SDK");
            sb.AppendLine("  - `redirect` — object with `url` (customer returns here after 3-D Secure)");
            sb.AppendLine("  - `post` — object with `url` (server webhook that receives the charge object)");
            sb.AppendLine("  - `threeDSecure` — boolean (default true)");
            sb.AppendLine("- Saudi methods: mada, Apple Pay, Visa/Mastercard, Benefit, KNET, STC Pay.");
            sb.AppendLine("- Frontend: Tap **Web Card SDK v2** (`tap-card-sdk`) or hosted **goSell** checkout — tokenizes the card in-browser and returns a `source` id you pass to `POST /charges`.");
            sb.AppendLine("- Webhook: Tap POSTs the charge to your `post.url`; verify the `hashstring` HMAC header before trusting `status == \"CAPTURED\"`.");
            sb.AppendLine("- Dashboard / keys: https://dashboard.tap.company  •  Docs: https://developers.tap.company/");
        }
        else if (key == "moyasar")
        {
            sb.AppendLine("# Payment integration — Moyasar (KSA)");
            sb.AppendLine();
            sb.AppendLine("- API base: `https://api.moyasar.com/v1/`");
            sb.AppendLine("- Auth: **HTTP Basic** — the secret key is the username and the password is left EMPTY. Secret keys are `sk_test_…` / `sk_live_…`; publishable `pk_test_…` / `pk_live_…` is safe in client code.");
            sb.AppendLine("- Create a payment: `POST /payments`. Required fields:");
            sb.AppendLine("  - `amount` — **INTEGER in the smallest unit (halalas), i.e. ×100.** 10.00 SAR is sent as `1000`. This is the OPPOSITE of Tap.");
            sb.AppendLine("  - `currency` — `\"SAR\"`");
            sb.AppendLine("  - `source` — object whose `type` is `creditcard` | `token` | `applepay` | `stcpay`");
            sb.AppendLine("  - `callback_url` — required for `creditcard`/`token`; the payer is returned here after the card flow");
            sb.AppendLine("  - `description` — optional label");
            sb.AppendLine("- Saudi methods: creditcard (Visa, Mastercard, mada, UnionPay), Apple Pay, STC Pay.");
            sb.AppendLine("- Frontend: **moyasar.js** hosted form. Init example:");
            sb.AppendLine("  ```js");
            sb.AppendLine("  Moyasar.init({");
            sb.AppendLine("    element: '.mysr-form',");
            sb.AppendLine("    amount: 1000,               // 10.00 SAR in halalas");
            sb.AppendLine("    currency: 'SAR',");
            sb.AppendLine("    description: 'Order #1',");
            sb.AppendLine("    publishable_api_key: 'pk_test_xxx',");
            sb.AppendLine("    callback_url: 'https://your.app/thanks',");
            sb.AppendLine("    methods: ['creditcard', 'applepay', 'stcpay'],");
            sb.AppendLine("    supported_networks: ['visa', 'mastercard', 'mada']");
            sb.AppendLine("  });");
            sb.AppendLine("  ```");
            sb.AppendLine("  (Load moyasar.js + its CSS from the Moyasar CDN.)");
            sb.AppendLine("- Webhook: configure in the dashboard; verify the `secret_token` in the payload before marking a payment `paid`.");
            sb.AppendLine("- Dashboard / keys: https://dashboard.moyasar.com  •  Docs: https://docs.moyasar.com/");
        }
        else
        {
            sb.AppendLine("# Payment integration — " + (saasPay.SelectedItem ?? "None"));
            sb.AppendLine();
            sb.AppendLine("Open SaaS ships first-class support for Stripe and Lemon Squeezy.");
            sb.AppendLine("See https://docs.opensaas.sh/guides/payments-integration/ and wire keys in `.env.server`.");
        }
        if (key != "none")
        {
            sb.AppendLine();
            sb.AppendLine("## .env.server keys (stub — never commit real secrets)");
            foreach (var v in PaymentEnvVars(key)) sb.AppendLine(v);
        }
        return sb.ToString();
    }

    void ShowPaymentGuide()
    {
        string key = PaymentKey();
        saasStatus.Text = PaymentSpec(key);
        SaasLog("");
        SaasLog("Opening the official docs in your browser…");
        try { Process.Start(PaymentDocsUrl(key)); } catch { }
    }

    void SaasBuild()
    {
        string app = SaasAppDir();
        if (!Directory.Exists(app)) { MessageBox.Show("App folder not found. Run step 2 first:\n" + app, "Hydra"); return; }
        if ((saasPitch.Text ?? "").Trim().Length == 0) { MessageBox.Show("Add a one-line pitch first so Claude understands the vision.", "Hydra"); return; }
        try
        {
            File.WriteAllText(Path.Combine(app, "PLAYBOOK.md"), PlaybookDoc());
            File.WriteAllText(Path.Combine(app, "VISION.md"), BuildVisionDoc());
            SaasLog("Wrote VISION.md into " + app);
            string pkey = PaymentKey();
            if (pkey != "none")
            {
                File.WriteAllText(Path.Combine(app, "PAYMENTS.md"), PaymentSpec(pkey));
                SaasLog("Wrote PAYMENTS.md (verified " + saasPay.SelectedItem + " integration spec).");
            }
            if (AiEnabled())
            {
                File.WriteAllText(Path.Combine(app, "AI.md"), AiSpec());
                File.WriteAllText(Path.Combine(app, ".env.ai.example"), AiEnvExample());
                SaasLog("Wrote AI.md + .env.ai.example (integrated multi-provider AI router).");
            }
            File.WriteAllText(Path.Combine(app, "ANALYTICS.md"), AnalyticsSpec());
            File.WriteAllText(Path.Combine(app, ".env.analytics.example"), AnalyticsEnvExample());
            SaasLog("Wrote ANALYTICS.md + .env.analytics.example (Google Analytics 4 — mandatory).");
        }
        catch (Exception ex) { SaasLog("Could not write VISION.md: " + ex.Message); return; }

        // launch the selected builder in the app folder as a managed terminal, primed with the build prompt,
        // using the chosen build model.
        string prompt = "FIRST read PLAYBOOK.md in this folder — the battle-tested production sequence and pitfall list; follow its phase order throughout. Then read VISION.md (and PAYMENTS.md / AI.md if present) in this folder and build the SaaS it describes on top of the Open SaaS template (" + SaasTemplateRepo + "). If the folder is not an Open SaaS app yet (no main.wasp), scaffold it FIRST with `wasp new -t saas` — Open SaaS is the mandatory base for every use case; never substitute another starter. If AI.md is present, add its multi-provider router (src/server/ai/router.ts) and route every AI feature through it. Wire Google Analytics 4 per ANALYTICS.md — mandatory for every use case (consent-gated gtag, required events, admin stats job; env ids stubbed). Start by summarizing the plan and asking me to confirm before major changes." + SaasSkillsHint();
        SaasLaunchBuilder(app, prompt);
        SaasLog("Opened a " + SaasBuilderName() + " session in the Workspace to build it.");
    }

    void SaasRun()
    {
        string app = SaasAppDir();
        if (!Directory.Exists(app)) { MessageBox.Show("App folder not found. Run step 2 first.", "Hydra"); return; }
        bool haveWasp = OnPath("wasp.exe") || OnPath("wasp");
        try
        {
            ProcessStartInfo dbPsi, appPsi;
            if (haveWasp)
            {
                dbPsi = new ProcessStartInfo("cmd.exe", "/k cd /d \"" + app + "\" && wasp start db") { UseShellExecute = true };
                appPsi = new ProcessStartInfo("cmd.exe", "/k cd /d \"" + app + "\" && wasp db migrate-dev && wasp start") { UseShellExecute = true };
            }
            else
            {
                string wp = ToWslPath(app);
                dbPsi = new ProcessStartInfo("wsl.exe", "bash -lic \"cd '" + wp + "' && wasp start db; exec bash\"") { UseShellExecute = true };
                appPsi = new ProcessStartInfo("wsl.exe", "bash -lic \"cd '" + wp + "' && wasp db migrate-dev && wasp start; exec bash\"") { UseShellExecute = true };
            }
            Process.Start(dbPsi);
            SaasLog("Started 'wasp start db' (leave it running).");
            Thread.Sleep(1500);
            Process.Start(appPsi);
            SaasLog("Started migrate + 'wasp start'. App will open on http://localhost:3000 shortly.");
        }
        catch (Exception ex) { SaasLog("Run failed: " + ex.Message); }
    }
}
