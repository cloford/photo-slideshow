namespace PhotoSlideshow;

internal sealed class SettingsDialog : Form
{
    private readonly TextBox seconds = new() { MaxLength = 4, Width = 70 };
    private readonly ComboBox start = Choice("前回の続き", "先頭から");
    private readonly ComboBox area = Choice("画面全体", "操作バー分の余白を確保");
    private readonly ComboBox edge = Choice("上", "下", "カスタム");
    private readonly CheckBox clock = new() { Text = "表示する", AutoSize = true };
    private readonly ComboBox style = Choice("アナログ", "デジタル");
    private readonly ComboBox side = Choice("左上", "右上", "カスタム");
    private readonly TextBox delay = new() { Width = 70, MaxLength = 3 };
    private readonly ComboBox notice = Choice("左上", "右上", "カスタム");
    private readonly Label error = new() { AutoSize = true, ForeColor = Color.LightCoral };
    public string? FolderPath { get; private set; }
    [System.ComponentModel.DesignerSerializationVisibility(System.ComponentModel.DesignerSerializationVisibility.Hidden)]
    public Action<Options>? Preview { get; set; }
    [System.ComponentModel.DesignerSerializationVisibility(System.ComponentModel.DesignerSerializationVisibility.Hidden)]
    public Func<Options, bool>? Persist { get; set; }
    [System.ComponentModel.DesignerSerializationVisibility(System.ComponentModel.DesignerSerializationVisibility.Hidden)]
    internal Action<SettingsDialog>? EditLayout { get; set; }
    private Options draft;
    private bool updatingLayout;
    public Options Value => draft with
    {
        Seconds = int.TryParse(seconds.Text, out int duration) ? duration : 5, BarHideSeconds = int.TryParse(delay.Text, out int parsed) ? parsed : 3,
        NoticeAtLeft = notice.SelectedIndex == 2 ? draft.NoticeAtLeft : notice.SelectedIndex == 0,
        HeartPlacement = draft.HeartPlacement with { UsePresetPosition = notice.SelectedIndex != 2 },
        FromBeginning = start.SelectedIndex == 1, ReserveBarSpace = area.SelectedIndex == 1,
        BarAtTop = edge.SelectedIndex == 2 ? draft.BarAtTop : edge.SelectedIndex == 0,
        BarPlacement = draft.BarPlacement with { UsePresetPosition = edge.SelectedIndex != 2 },
        ClockVisible = clock.Checked, AnalogClock = style.SelectedIndex == 0,
        ClockAtLeft = side.SelectedIndex == 2 ? draft.ClockAtLeft : side.SelectedIndex == 0,
        ClockPlacement = draft.ClockPlacement with { UsePresetPosition = side.SelectedIndex != 2 }
    };

    internal void UpdateLayout(Options value)
    {
        draft = value;
        updatingLayout = true;
        SetChoice(edge, value.BarPlacement, value.BarAtTop);
        SetChoice(side, value.ClockPlacement, value.ClockAtLeft);
        SetChoice(notice, value.HeartPlacement, value.NoticeAtLeft);
        updatingLayout = false;
        Preview?.Invoke(Value);
    }

    private static void SetChoice(ComboBox control, OverlayPlacement placement, bool first)
    {
        if (placement.Position is null && control.Items.Count == 3) control.Items.RemoveAt(2);
        if (placement.Position is not null && control.Items.Count == 2) control.Items.Add("カスタム");
        control.SelectedIndex = placement.Custom ? 2 : first ? 0 : 1;
    }

    public SettingsDialog(Options value)
    {
        draft = value;
        Text = "設定";
        BackColor = Color.FromArgb(27, 28, 31);
        ForeColor = Color.White;
        Font = new Font("Yu Gothic UI", 11);
        ClientSize = new Size(650, 660);
        ControlBox = false;
        MinimizeBox = MaximizeBox = false;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.CenterParent;
        seconds.Text = value.Seconds.ToString();
        start.SelectedIndex = value.FromBeginning ? 1 : 0;
        area.SelectedIndex = value.ReserveBarSpace ? 1 : 0;
        clock.Checked = value.ClockVisible;
        style.SelectedIndex = value.AnalogClock ? 0 : 1;
        delay.Text = value.BarHideSeconds.ToString();
        UpdateLayout(value);
        foreach (var choice in new[] { area, edge, style, side, notice })
            choice.SelectedIndexChanged += (_, _) => { if (!updatingLayout) Preview?.Invoke(Value); };
        clock.CheckedChanged += (_, _) => Preview?.Invoke(Value);

        var table = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, AutoScroll = true, Padding = new Padding(22) };
        table.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 198));
        table.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        void Section(string label)
        {
            var item = new Label { Text = label, AutoSize = true, Margin = new Padding(3, 14, 3, 8),
                Font = new Font(Font, FontStyle.Bold) };
            table.Controls.Add(item, 0, table.RowCount++);
            table.SetColumnSpan(item, 2);
        }
        void Row(string label, Control control)
        {
            int row = table.RowCount++;
            table.Controls.Add(new Label { Text = label, AutoSize = true, Margin = new Padding(3, 7, 3, 5) }, 0, row);
            control.AccessibleName = label.Length == 0 ? control.AccessibleName : label;
            table.Controls.Add(control, 1, row);
        }
        Section("再生");
        Row("1枚の表示時間（秒）", seconds);
        var presets = new FlowLayoutPanel { AutoSize = true, WrapContents = false };
        foreach (int preset in new[] {3, 5, 10, 15, 30, 60})
        {
            var button = new Button { Text = $"{preset}秒", AutoSize = true, BackColor = Color.FromArgb(52, 54, 58) };
            button.Click += (_, _) => seconds.Text = preset.ToString();
            presets.Controls.Add(button);
        }
        Row("", presets);
        Row("起動位置", start);
        Section("画面表示");
        Row("画像の表示領域", area);
        Row("操作バーの位置", edge);
        Section("時計");
        Row("時計を表示", clock);
        Row("時計の種類", style);
        Row("時計の位置", side);
        Section("操作バーと通知");
        Row("操作バーを隠すまで（秒）", delay);
        Row("お気に入りの位置", notice);
        var edit = new Button { Text = "配置を編集", AutoSize = true };
        edit.Click += (_, _) => EditLayout?.Invoke(this);
        Row("", edit);
        table.Controls.Add(error, 0, table.RowCount++);
        table.SetColumnSpan(error, 2);
        var actions = new FlowLayoutPanel { AutoSize = true };
        var close = new Button { Text = "閉じる", AutoSize = true, BackColor = Color.FromArgb(38, 84, 195) };
        close.Click += (_, _) =>
        {
            if (!int.TryParse(delay.Text, out int hide) || hide < 1 || hide > 60)
            {
                error.Text = "バーを隠す時間は1〜60秒で入力してください。";
                return;
            }
            if (!int.TryParse(seconds.Text, out int duration) || duration < 1 || duration > 300)
            {
                error.Text = "表示秒数は1〜300秒で入力してください。";
                return;
            }
            if (Persist?.Invoke(Value) == false)
            {
                error.Text = "設定を保存できませんでした。再試行してください。";
                return;
            }
            DialogResult = DialogResult.OK;
        };
        var folder = new Button { Text = "画像フォルダを選ぶ", AutoSize = true };
        folder.Click += (_, _) =>
        {
            using var chooser = new FolderBrowserDialog { Description = "再生する画像フォルダを選んでください" };
            if (chooser.ShowDialog(this) == DialogResult.OK)
            {
                FolderPath = chooser.SelectedPath;
                folder.Text = "画像フォルダを選択済み";
            }
        };
        actions.Controls.AddRange([folder, close]);
        table.Controls.Add(actions, 0, table.RowCount++);
        table.SetColumnSpan(actions, 2);
        Controls.Add(table);
        AcceptButton = close;
    }

    private static ComboBox Choice(params string[] values)
    {
        var control = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 250 };
        control.Items.AddRange(values);
        return control;
    }
}

internal sealed class PhotoListDialog : Form
{
    private readonly PhotoGrid grid;
    public int Selected { get; private set; } = -1;

    public PhotoListDialog(PhotoFile[] photos, int current, Func<int, bool> favorite, Func<int, bool> delete)
    {
        Text = "写真一覧";
        ClientSize = new(744, 600);
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.CenterParent;
        MinimizeBox = MaximizeBox = false;
        grid = new PhotoGrid(photos, current, favorite) { Dock = DockStyle.Fill };
        var actions = new FlowLayoutPanel { Dock = DockStyle.Top, Height = 40 };
        var all = new RadioButton { Appearance = Appearance.Button, Text = "すべて", AutoSize = true, Checked = true };
        var marked = new RadioButton { Appearance = Appearance.Button, Text = "お気に入り", AutoSize = true };
        var close = new Button { Text = "閉じる", DialogResult = DialogResult.Cancel, AutoSize = true };
        marked.CheckedChanged += (_, _) => grid.Filter(marked.Checked, keepOffset: false);
        grid.OpenPhoto = index => { Selected = index; DialogResult = DialogResult.OK; };
        grid.RemoveFavorite = index =>
        {
            if (delete(index)) grid.Filter(marked.Checked, keepOffset: true);
        };
        actions.Controls.AddRange([all, marked, close]);
        Controls.Add(grid);
        Controls.Add(actions);
        Shown += (_, _) => grid.ScrollToCurrent();
        CancelButton = close;
    }
}
