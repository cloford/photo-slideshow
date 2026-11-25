using System.Drawing.Drawing2D;

namespace PhotoSlideshow;

internal sealed class LayoutEditor : Form
{
    private readonly PlaybackSurface preview = new() { Dock = DockStyle.Fill, Editing = true };
    private readonly FlowLayoutPanel footer = new()
    {
        AutoSize = true, WrapContents = false, Padding = new Padding(8), BackColor = Color.FromArgb(27, 28, 31)
    };
    private readonly ComboBox selected = new() { DropDownStyle = ComboBoxStyle.DropDownList, Width = 124 };
    private sealed record Drag(OverlayItem Item, Point Start, RectangleF Frame, PointF? Corner);
    private Drag? drag;
    private OverlayItem Item => (OverlayItem)Math.Max(0, selected.SelectedIndex);
    private static readonly OverlayItem[] Items = Enum.GetValues<OverlayItem>();
    public Options Value => preview.Options;

    public LayoutEditor(Options value, Rectangle bounds, Bitmap? displayedImage, Action<Options> live)
    {
        Text = "配置を編集";
        AccessibleName = Text;
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        Bounds = bounds;
        ShowInTaskbar = false;
        TopMost = true;
        BackColor = Color.Black;
        AutoScaleMode = AutoScaleMode.Dpi;
        ForeColor = Color.White;
        preview.Options = value with { };
        preview.SetPhoto(displayedImage, 1);
        preview.Paint += (_, e) => DrawFrames(e.Graphics);
        preview.MouseDown += (_, e) => StartDrag(e);
        preview.MouseMove += (_, e) => ContinueDrag(e);
        preview.MouseUp += (_, _) => FinishDrag();
        preview.MouseCaptureChanged += (_, _) => { if (!preview.Capture) FinishDrag(); };
        preview.SizeChanged += (_, _) => PositionFooter();
        Controls.Add(preview);
        Controls.Add(footer);
        footer.BringToFront();
        selected.AccessibleName = "配置を編集する要素";
        selected.Items.AddRange(["時計", "お気に入り", "操作バー"]);
        selected.SelectedIndex = 0;
        selected.SelectedIndexChanged += (_, _) => { PositionFooter(); preview.Invalidate(); };
        footer.Controls.Add(selected);

        void Reset(bool position, bool size, bool all = false)
        {
            foreach (var item in all ? Items : [Item])
            {
                if (position) Value.ResetPosition(item);
                if (size) Value.SetPlacement(item, Value.Placement(item) with { Scale = 1 });
            }
            Publish();
        }
        Button AddButton(string label, Action action)
        {
            var button = new Button { Text = label, AutoSize = true, BackColor = Color.FromArgb(52, 54, 58) };
            button.Click += (_, _) => action();
            footer.Controls.Add(button);
            return button;
        }
        void Publish()
        {
            PositionFooter();
            preview.Invalidate();
            live(Value with { });
        }
        Changed = Publish;
        AddButton("位置を戻す", () => Reset(true, false));
        AddButton("サイズを戻す", () => Reset(false, true));
        AddButton("すべて初期値に戻す", () => Reset(true, true, true));
        CancelButton = AddButton("設定に戻る", () => Close());
        Shown += (_, _) => PositionFooter();
    }

    protected override void WndProc(ref Message message)
    {
        const int displayChange = 0x007E;
        base.WndProc(ref message);
        if (message.Msg == displayChange && IsHandleCreated && !IsDisposed)
            BeginInvoke(() => { if (!IsDisposed) Bounds = Screen.FromHandle(Handle).Bounds; });
    }

    private Action Changed { get; }
    private void PositionFooter()
    {
        var size = footer.PreferredSize;
        var lower = new Rectangle((ClientSize.Width - size.Width) / 2, ClientSize.Height - size.Height - 7,
            size.Width, size.Height);
        var anchor = drag?.Frame ?? preview.Geometry.Frame(Item);
        footer.Location = anchor.IntersectsWith(lower) ? new Point(lower.X, 7) : lower.Location;
    }

    private static PointF[] Corners(RectangleF frame) =>
        [new(frame.Left, frame.Top), new(frame.Right, frame.Top), new(frame.Left, frame.Bottom), new(frame.Right, frame.Bottom)];

    private void StartDrag(MouseEventArgs e)
    {
        if (e.Button != MouseButtons.Left) return;
        var geometry = preview.Geometry;
        foreach (var item in Items.OrderBy(item => item == Item ? 0 : 1))
        {
            var frame = geometry.Frame(item);
            PointF? corner = Corners(frame).Where(p => Distance(p, e.Location) < 11 * geometry.Dpi)
                .Select(p => (PointF?)p).FirstOrDefault();
            if (corner is null && !frame.Contains(e.Location)) continue;
            drag = new(item, e.Location, frame, corner);
            selected.SelectedIndex = (int)item;
            preview.Capture = true;
            preview.Invalidate();
            break;
        }
    }

    private static float Distance(PointF first, PointF second) =>
        MathF.Sqrt(MathF.Pow(first.X - second.X, 2) + MathF.Pow(first.Y - second.Y, 2));

    private void ContinueDrag(MouseEventArgs e)
    {
        if (drag is not { } session || !preview.Capture) return;
        var geometry = preview.Geometry;
        var frame = session.Frame;
        float dx = e.X - session.Start.X, dy = e.Y - session.Start.Y;
        float scale = Value.Placement(session.Item).Scale;
        if (session.Corner is { } corner)
        {
            float sx = corner.X == frame.Left ? -1 : 1, sy = corner.Y == frame.Top ? -1 : 1;
            var anchor = new PointF(corner.X - sx * frame.Width, corner.Y - sy * frame.Height);
            var size = geometry.BaseSize(session.Item);
            float projection = (dx * sx * size.Width + dy * sy * size.Height) /
                (size.Width * size.Width + size.Height * size.Height);
            float roomX = (sx < 0 ? anchor.X - geometry.Safe.Left : geometry.Safe.Right - anchor.X) / size.Width;
            float roomY = (sy < 0 ? anchor.Y - geometry.Safe.Top : geometry.Safe.Bottom - anchor.Y) / size.Height;
            float upper = Math.Min(geometry.MaxScale(session.Item), Math.Min(roomX, roomY));
            scale = Math.Clamp(frame.Width / size.Width + projection, 0.55f, Math.Max(0.55f, upper));
            float width = size.Width * scale, height = size.Height * scale;
            frame = new(anchor.X - (sx < 0 ? width : 0), anchor.Y - (sy < 0 ? height : 0), width, height);
        }
        else frame.Offset(dx, dy);
        Value.SetPlacement(session.Item, geometry.Placement(frame, scale));
        Changed();
    }

    private void FinishDrag()
    {
        if (drag is null) return;
        drag = null;
        preview.Capture = false;
        PositionFooter();
        preview.Invalidate();
    }

    private void DrawFrames(Graphics graphics)
    {
        var geometry = preview.Geometry;
        var toolbar = geometry.Frame(OverlayItem.Bar);
        var state = graphics.Save();
        graphics.TranslateTransform(toolbar.Left, toolbar.Top);
        float scale = toolbar.Width / 510;
        graphics.ScaleTransform(scale, scale);
        using var background = new SolidBrush(Color.FromArgb(27, 28, 31));
        graphics.FillRectangle(background, 0, 0, 510, 65);
        using var glyphFont = new Font("Segoe UI Symbol", 24, FontStyle.Regular, GraphicsUnit.Pixel);
        using var alignment = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
        string[] icons = ["❮", "Ⅱ", "❯", "▦", "♡", "⚙", "↶"];
        for (int index = 0; index < icons.Length; index++)
            graphics.DrawString(icons[index], glyphFont, index == 4 ? Brushes.Silver : Brushes.White,
                new RectangleF(10 + 70 * index, 10, 70, 45), alignment);
        graphics.Restore(state);

        // Draw the chosen frame last so handles are accessible when frames overlap.
        foreach (var item in Items.OrderBy(item => item == Item ? 1 : 0))
        {
            var frame = geometry.Frame(item);
            using var border = new Pen(item == Item ? Color.Turquoise : Color.WhiteSmoke, 2);
            graphics.DrawRectangle(border, frame.X, frame.Y, frame.Width, frame.Height);
            foreach (var corner in Corners(frame))
            {
                var handle = new RectangleF(corner.X - 5, corner.Y - 5, 10, 10);
                graphics.FillRectangle(Brushes.Black, handle);
                graphics.DrawRectangle(border, handle.X, handle.Y, handle.Width, handle.Height);
            }
        }
        if (drag is null) return;
        using var guide = new Pen(Color.Turquoise) { DashStyle = DashStyle.Dash };
        var active = geometry.Frame(Item);
        var safe = geometry.Safe;
        foreach (float x in new[] { 1, safe.Width / 2, safe.Right - 1 })
            if (new[] { active.Left, active.Left + active.Width / 2, active.Right }.Any(pos => Math.Abs(pos - x) < 14))
                graphics.DrawLine(guide, x, 0, x, safe.Bottom);
        foreach (float y in new[] { 1, safe.Height / 2, safe.Bottom - 1 })
            if (new[] { active.Top, active.Top + active.Height / 2, active.Bottom }.Any(pos => Math.Abs(pos - y) < 14))
                graphics.DrawLine(guide, 0, y, safe.Right, y);
    }
}
