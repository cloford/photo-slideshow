using System.Runtime.InteropServices;

namespace PhotoSlideshow;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        ApplicationConfiguration.Initialize();
        using var single = new Mutex(true, @"Local\Cloford.PhotoSlideshow", out bool first);
        if (!first) return;
        Application.Run(new Slideshow());
    }
}

internal sealed class Slideshow : Form
{
    private const uint Continuous = 0x80000000;
    private const uint DisplayRequired = 0x00000002;
    [DllImport("kernel32.dll")] private static extern uint SetThreadExecutionState(uint state);
    private readonly Store store;
    private readonly UserData data;
    private readonly PlaybackSurface surface = new() { Dock = DockStyle.Fill };
    private readonly FlowLayoutPanel bar = new()
    {
        AutoSize = false, WrapContents = false, FlowDirection = FlowDirection.LeftToRight,
        Padding = new Padding(10), BackColor = Color.FromArgb(27, 28, 31)
    };
    private readonly System.Windows.Forms.Timer nextTimer = new();
    private readonly System.Windows.Forms.Timer refresh = new() { Interval = 40 };
    private readonly Button play;
    private readonly Button star;
    private readonly ToolTip tooltips = new();
    private Font? toolbarFont;
    private float toolbarFontScale;
    private string? folder;
    private PhotoFile[] files = [];
    private int shown = -1;
    private int requested = -1;
    private int revision;
    private int generation;
    private bool paused;
    private bool dialog;
    private bool powerHeld;
    private bool shuttingDown;
    private bool loading;
    private DateTime barUntil;
    private DateTime starUntil;
    private bool barWasRequired;
    private readonly SemaphoreSlim imageDecoders = new(2);
    private CancellationTokenSource? pendingRequest;

    public Slideshow(Store? store = null)
    {
        this.store = store ?? new Store(Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Cloford", "PhotoSlideshow", "state.json"));
        Text = "写真スライドショー";
        data = this.store.Read();
        surface.Options = data.Settings;
        surface.AddFavorite = ToggleFavorite;
        surface.MovePhoto = MovePhoto;
        surface.ZoomChanged = Schedule;
        surface.FrameDrawn = drawn =>
        {
            if (drawn == revision && shown >= 0 && folder is not null)
                data.LastByFolder[folder] = files[shown].ID;
        };
        Controls.Add(surface);
        Controls.Add(bar);
        bar.BringToFront();
        bar.Visible = false;
        AddButton("❮", "前へ", () => MovePhoto(-1));
        play = AddButton("Ⅱ", "一時停止／再開", TogglePause);
        AddButton("❯", "次へ", () => MovePhoto(1));
        AddButton("▦", "写真一覧", OpenList);
        star = AddButton("♡", "お気に入りに登録", () => { if (surface.DrawnRevision == revision) SetFavorite(shown, true); });
        AddButton("⚙", "設定", Configure);
        AddButton("↶", "元の画面に戻る", Close);
        nextTimer.Tick += (_, _) => { nextTimer.Stop(); MovePhoto(1); };
        refresh.Tick += (_, _) =>
        {
            UpdateBarVisibility();
            if (surface.Options.ClockVisible || surface.EffectActive) surface.Invalidate();
            if (starUntil != default && DateTime.UtcNow >= starUntil)
            {
                starUntil = default;
                UpdateStar();
            }
        };
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        Bounds = Screen.FromPoint(Cursor.Position).Bounds;
        TopMost = true;
        BackColor = Color.Black;
        KeyPreview = true;
        Shown += async (_, _) =>
        {
            refresh.Start();
            LayoutBar();
            if (!this.store.CanSave) surface.Status = "保存データを読み込めませんでした。";
            if (data.Folder is { } previous && await OpenFolder(previous)) return;
            await ChooseFolder();
        };
        Resize += (_, _) => LayoutBar();
        surface.DpiChangedAfterParent += (_, _) => LayoutBar();
        FormClosed += (_, _) =>
        {
            shuttingDown = true;
            ++generation;
            pendingRequest?.Cancel();
            nextTimer.Dispose();
            refresh.Dispose();
            tooltips.Dispose();
            toolbarFont?.Dispose();
            SetPower(false);
            Save();
        };
    }

    private Button AddButton(string icon, string name, Action action)
    {
        var button = new Button
        {
            Text = icon, AccessibleName = name, Width = 64, Height = 45, ForeColor = Color.White,
            FlatStyle = FlatStyle.Flat, TabStop = true
        };
        button.FlatAppearance.BorderSize = 0;
        button.Click += (_, _) => action();
        bar.Controls.Add(button);
        tooltips.SetToolTip(button, name);
        return button;
    }

    private void LayoutBar()
    {
        if (!IsHandleCreated || star is null) return;
        var screen = new RectangleF(0, 0, Math.Max(1, ClientSize.Width), Math.Max(1, ClientSize.Height));
        var geometry = new OverlayFrames(screen, surface.Options, DeviceDpi / 96f);
        bar.Bounds = Rectangle.Round(geometry.Frame(OverlayItem.Bar));
        float scale = bar.Width / 510f;
        bar.SuspendLayout();
        bar.Padding = new Padding((int)Math.Round(10 * scale), 0, 0, 0);
        if (toolbarFontScale != scale)
        {
            var previous = toolbarFont;
            toolbarFont = new Font("Segoe UI Symbol", 24 * Math.Max(0.1f, scale), FontStyle.Regular, GraphicsUnit.Pixel);
            foreach (Control button in bar.Controls) button.Font = toolbarFont;
            previous?.Dispose();
            toolbarFontScale = scale;
        }
        for (int index = 0; index < bar.Controls.Count; index++)
        {
            var button = bar.Controls[index];
            int left = (int)Math.Round((10 + 70 * index) * scale);
            int right = (int)Math.Round((10 + 70 * (index + 1)) * scale);
            int height = (int)Math.Round(45 * scale);
            button.Size = new Size(right - left, height);
            button.Margin = new Padding(0, (bar.Height - height) / 2, 0, 0);
        }
        bar.ResumeLayout(true);
        surface.BarBounds = bar.Bounds;
        int heartIndex = bar.Controls.IndexOf(star);
        surface.FavoriteOrigin = new PointF(bar.Left + (45 + heartIndex * 70) * scale,
            bar.Top + bar.Height / 2f);
        surface.Invalidate();
    }

    protected override void WndProc(ref Message message)
    {
        const int displayChange = 0x007E;
        base.WndProc(ref message);
        if (message.Msg == displayChange && IsHandleCreated && !shuttingDown)
            BeginInvoke(() => { if (!shuttingDown) Bounds = Screen.FromHandle(Handle).Bounds; });
    }

    protected override void OnMouseWheel(MouseEventArgs e)
    {
        if (!dialog) surface.ApplyWheel(e.Delta, surface.PointToClient(Cursor.Position));
        base.OnMouseWheel(e);
    }

    private void UpdateBarVisibility()
    {
        var nearby = surface.BarBounds;
        int padding = Math.Max(8, (int)Math.Round(nearby.Width / 510f * 22));
        nearby.Inflate(padding, padding);
        var pointer = PointToClient(Cursor.Position);
        bool required = dialog || (shown < 0 && !loading) || (ClientRectangle.Contains(pointer) && nearby.Contains(pointer));
        var now = DateTime.UtcNow;
        if (barWasRequired && !required) barUntil = now.AddSeconds(surface.Options.BarHideSeconds);
        barWasRequired = required;
        bar.Visible = required || now < barUntil;
    }

    protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
    {
        if (!dialog)
        {
            switch (keyData)
            {
                case Keys.Escape: Close(); return true;
                case Keys.Space when ActiveControl is not Button: TogglePause(); return true;
                case Keys.Left: MovePhoto(-1); return true;
                case Keys.Right: MovePhoto(1); return true;
            }
        }
        return base.ProcessCmdKey(ref msg, keyData);
    }

    private async Task ChooseFolder()
    {
        using var chooser = new FolderBrowserDialog { Description = "再生する画像フォルダを選んでください", UseDescriptionForTitle = true };
        bool confirmed = ShowChild(chooser) == DialogResult.OK;
        if (confirmed && await OpenFolder(chooser.SelectedPath)) return;
        if (confirmed)
            MessageBox.Show(this, "画像が見つからないか、フォルダを読み込めませんでした。", Text);
        if (folder is null) Close();
    }

    private async Task<bool> OpenFolder(string path)
    {
        int opening = ++generation;
        pendingRequest?.Cancel();
        nextTimer.Stop();
        loading = true;
        surface.Status = "フォルダを読み込み中…";
        PhotoFile[] result;
        string fullPath;
        try
        {
            fullPath = Path.TrimEndingDirectorySeparator(Path.GetFullPath(path));
            result = await Task.Run(() => FolderSource.Scan(fullPath)).WaitAsync(TimeSpan.FromSeconds(15));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException or TimeoutException)
        {
            result = [];
            fullPath = path;
        }
        if (shuttingDown || opening != generation) return false;
        loading = false;
        if (result.Length == 0)
        {
            surface.Status = shown >= 0 ? "" : "表示できる写真がありません。";
            Schedule();
            return false;
        }
        folder = fullPath;
        data.Folder = fullPath;
        files = result;
        shown = -1;
        requested = -1;
        surface.SetPhoto(null, ++revision);
        surface.IsFavorite = false;
        SetPower(true);
        data.LastByFolder.TryGetValue(fullPath, out string? prior);
        Request(FolderSource.StartIndex(files, prior, data.Settings.FromBeginning), 1, skip: true);
        Save();
        return true;
    }

    private void MovePhoto(int direction)
    {
        if (dialog || files.Length < 2) return;
        int current = requested < 0 ? shown : requested;
        Request(Wrap(current + direction), direction, skip: true);
    }

    private int Wrap(int index) => (index + files.Length) % files.Length;

    private async void Request(int index, int direction, bool skip)
    {
        nextTimer.Stop();
        pendingRequest?.Cancel();
        using var work = new CancellationTokenSource();
        pendingRequest = work;
        int token = ++generation;
        PhotoFile[] snapshot = files;
        requested = index;
        loading = true;
        surface.Status = "写真を読み込み中…";

        try
        {
            for (int remaining = skip ? snapshot.Length : 1; remaining > 0; remaining--, index = Wrap(index + direction))
            {
                if (token != generation || shuttingDown) return;
                if (shown == index) break;

                Bitmap? image = await Decode(snapshot[index], work.Token);
                if (token != generation || shuttingDown)
                {
                    image?.Dispose();
                    return;
                }
                if (image is null) continue;

                shown = index;
                starUntil = default;
                surface.SetPhoto(image, ++revision);
                UpdateStar();
                break;
            }
            surface.Status = shown == -1 ? "このフォルダの写真を読み込めませんでした。" :
                !skip && shown != index ? "選んだ写真を読み込めませんでした。" : "";
            if (shown == -1) SetPower(false);
            requested = shown;
            loading = false;
            Schedule();
        }
        finally
        {
            if (ReferenceEquals(pendingRequest, work)) pendingRequest = null;
        }
    }

    private async Task<Bitmap?> Decode(PhotoFile file, CancellationToken cancellation)
    {
        var decoding = Task.Run(async () =>
        {
            await imageDecoders.WaitAsync(cancellation);
            try
            {
                cancellation.ThrowIfCancellationRequested();
                using var stream = new FileStream(file.FullPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
                using var source = Image.FromStream(stream, false, true);
                PlaybackSurface.Orient(source);
                return new Bitmap(source);
            }
            finally { imageDecoders.Release(); }
        });
        try { return await decoding.WaitAsync(TimeSpan.FromSeconds(15), cancellation); }
        catch (Exception)
        {
            _ = decoding.ContinueWith(done =>
            {
                if (done.IsCompletedSuccessfully) done.Result.Dispose();
                else _ = done.Exception;
            }, TaskScheduler.Default);
            return null;
        }
    }

    private void TogglePause()
    {
        if (dialog) return;
        paused = !paused;
        play.Text = paused ? "▶" : "Ⅱ";
        Schedule();
    }

    private void Schedule()
    {
        nextTimer.Stop();
        if (!paused && !dialog && !loading && shown >= 0 && files.Length > 1)
        {
            nextTimer.Interval = data.Settings.Seconds * 1000;
            nextTimer.Start();
        }
    }

    private bool IsFavorite(int index) => FavoriteIndex(index) >= 0;
    private int FavoriteIndex(int index)
    {
        if (index < 0 || index >= files.Length) return -1;
        return data.Favorites.FindIndex(item => item.SourceKind == FolderSource.Kind &&
            StringComparer.OrdinalIgnoreCase.Equals(item.SourceID, folder) &&
            StringComparer.OrdinalIgnoreCase.Equals(item.PhotoID, files[index].ID));
    }
    private void UpdateStar()
    {
        bool favorite = IsFavorite(shown);
        surface.IsFavorite = favorite;
        surface.Invalidate();
        star.Text = starUntil > DateTime.UtcNow ? "" : favorite ? "♥" : "♡";
        star.ForeColor = favorite ? Color.HotPink : Color.Silver;
    }
    private void ToggleFavorite(int expectedRevision)
    {
        if (expectedRevision == revision) SetFavorite(shown, !IsFavorite(shown));
    }
    private bool SetFavorite(int index, bool add)
    {
        if (index < 0) return false;
        int found = FavoriteIndex(index);
        if (add == (found >= 0)) return false;
        var before = data.Favorites.ToList();
        if (add)
        {
            var item = files[index];
            data.Favorites.Add(new(FolderSource.Kind, folder!, item.ID, DateTimeOffset.Now, item.Modified,
                surface.ImageWidth, surface.ImageHeight));
        }
        else data.Favorites.RemoveAt(found);
        if (!Save())
        {
            data.Favorites = before;
            surface.Status = "お気に入りを保存できませんでした。";
            return false;
        }
        bool falling = !add && index == shown;
        bool bouncing = add && bar.Visible;
        if (falling || bouncing) starUntil = DateTime.UtcNow.AddSeconds(falling ? 0.85 : 0.46);
        UpdateStar();
        surface.ShowFavoriteEffect(!add, falling, bouncing);
        return true;
    }

    private void Configure()
    {
        using var settings = new SettingsDialog(data.Settings) { StartPosition = FormStartPosition.CenterParent };
        settings.Preview = preview =>
        {
            surface.Options = preview;
            LayoutBar();
        };
        settings.EditLayout = owner =>
        {
            using var editor = new LayoutEditor(owner.Value, Bounds, surface.CopyImage(), value =>
            {
                surface.Options = value;
                LayoutBar();
            });
            editor.ShowDialog(owner);
            owner.UpdateLayout(editor.Value);
        };
        settings.Persist = value =>
        {
            var previous = data.Settings;
            data.Settings = value;
            if (Save()) return true;
            data.Settings = previous;
            return false;
        };
        var result = ShowChild(settings);
        surface.Options = data.Settings;
        surface.ResetZoom();
        LayoutBar();
        if (result == DialogResult.OK && settings.FolderPath is { } folderPath)
            _ = OpenSelectedFolder(folderPath);
    }

    private async Task OpenSelectedFolder(string path)
    {
        if (!await OpenFolder(path))
            MessageBox.Show(this, "画像が見つからないか、フォルダを読み込めませんでした。", Text);
    }

    private void OpenList()
    {
        if (files.Length == 0) return;
        using var list = new PhotoListDialog(files, shown, IsFavorite, index => SetFavorite(index, false));
        if (ShowChild(list) == DialogResult.OK && list.Selected >= 0)
            Request(list.Selected, 1, skip: false);
    }

    private DialogResult ShowChild(CommonDialog child)
    {
        nextTimer.Stop();
        dialog = true;
        try { return child.ShowDialog(this); }
        finally { dialog = false; Schedule(); }
    }

    private DialogResult ShowChild(Form child)
    {
        nextTimer.Stop();
        dialog = true;
        try { return child.ShowDialog(this); }
        finally { dialog = false; Schedule(); }
    }

    private bool Save() => store.Save(data);

    private void SetPower(bool required)
    {
        if (powerHeld == required) return;
        if (SetThreadExecutionState(Continuous | (required ? DisplayRequired : 0)) != 0)
            powerHeld = required;
    }
}
