namespace PhotoSlideshow;

internal sealed class SettingsDialog : Form
{
    private readonly NumericUpDown seconds = new() { Minimum = 1, Maximum = 300, Width = 70 };
    private readonly ComboBox start = Choice("前回の続き", "先頭から");
    private readonly ComboBox area = Choice("画面全体", "操作バー分の余白を確保");
    private readonly ComboBox edge = Choice("上", "下");
    private readonly CheckBox clock = new() { Text = "表示する", AutoSize = true };
    private readonly ComboBox style = Choice("アナログ", "デジタル");
    private readonly ComboBox side = Choice("左上", "右上");
    public bool ChangeFolder { get; private set; }
    public Options Value => new()
    {
        Seconds = (int)seconds.Value, FromBeginning = start.SelectedIndex == 1,
        ReserveBarSpace = area.SelectedIndex == 1, BarAtTop = edge.SelectedIndex == 0,
        ClockVisible = clock.Checked, AnalogClock = style.SelectedIndex == 0, ClockAtLeft = side.SelectedIndex == 0
    };

    public SettingsDialog(Options value)
    {
        Text = "設定";
        BackColor = Color.FromArgb(27, 28, 31);
        ForeColor = Color.White;
        Font = new Font("Yu Gothic UI", 11);
        ClientSize = new Size(650, 580);
        MinimizeBox = MaximizeBox = false;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.CenterParent;
        seconds.Value = value.Seconds;
        start.SelectedIndex = value.FromBeginning ? 1 : 0;
        area.SelectedIndex = value.ReserveBarSpace ? 1 : 0;
        edge.SelectedIndex = value.BarAtTop ? 0 : 1;
        clock.Checked = value.ClockVisible;
        style.SelectedIndex = value.AnalogClock ? 0 : 1;
        side.SelectedIndex = value.ClockAtLeft ? 0 : 1;

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
            button.Click += (_, _) => seconds.Value = preset;
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
        var actions = new FlowLayoutPanel { AutoSize = true };
        var close = new Button { Text = "閉じる", DialogResult = DialogResult.Cancel, AutoSize = true };
        var save = new Button { Text = "保存して閉じる", DialogResult = DialogResult.OK, AutoSize = true,
            BackColor = Color.FromArgb(38, 84, 195) };
        var folder = new Button { Text = "画像フォルダを選ぶ", AutoSize = true };
        folder.Click += (_, _) => { ChangeFolder = true; DialogResult = DialogResult.OK; };
        actions.Controls.AddRange([folder, close, save]);
        table.Controls.Add(actions, 0, table.RowCount++);
        table.SetColumnSpan(actions, 2);
        Controls.Add(table);
        AcceptButton = save;
        CancelButton = close;
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
    private readonly ListBox list = new() { Dock = DockStyle.Fill, AccessibleName = "写真一覧" };
    private readonly CheckBox filter = new() { Text = "お気に入りのみ", AutoSize = true };
    private readonly Button play = new() { Text = "表示", AutoSize = true };
    private readonly Button remove = new() { Text = "お気に入り解除", AutoSize = true };
    private sealed record Row(int Index, string Label) { public override string ToString() => Label; }
    public int Selected => (list.SelectedItem as Row)?.Index ?? -1;

    public PhotoListDialog(PhotoFile[] photos, int current, Func<int, bool> favorite, Func<int, bool> delete)
    {
        Text = "写真一覧";
        ClientSize = new Size(650, 510);
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.CenterParent;
        MinimizeBox = MaximizeBox = false;
        var actions = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 40 };
        var close = new Button { Text = "閉じる", DialogResult = DialogResult.Cancel, AutoSize = true };
        actions.Controls.AddRange([filter, play, remove, close]);
        Controls.Add(list);
        Controls.Add(actions);
        void UpdateActions()
        {
            play.Enabled = Selected >= 0;
            remove.Enabled = Selected >= 0 && favorite(Selected);
        }
        void Reload(int selected)
        {
            list.BeginUpdate();
            list.Items.Clear();
            for (int index = 0; index < photos.Length; index++)
            {
                bool marked = favorite(index);
                if (!filter.Checked || marked)
                {
                    int row = list.Items.Add(new Row(index, $"{index + 1}　{(marked ? "★　" : "")}{photos[index].ID}"));
                    if (index == selected) list.SelectedIndex = row;
                }
            }
            list.EndUpdate();
            UpdateActions();
        }
        filter.CheckedChanged += (_, _) => Reload(Selected);
        list.SelectedIndexChanged += (_, _) => UpdateActions();
        play.Click += (_, _) => { if (Selected >= 0) DialogResult = DialogResult.OK; };
        list.DoubleClick += (_, _) =>
        {
            if (list.IndexFromPoint(list.PointToClient(Cursor.Position)) >= 0) play.PerformClick();
        };
        remove.Click += (_, _) => { var index = Selected; if (index >= 0 && delete(index)) Reload(index); };
        Reload(current);
        CancelButton = close;
    }
}
