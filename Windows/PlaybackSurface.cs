using System.Drawing.Drawing2D;
using System.ComponentModel;
using System.Diagnostics;

namespace PhotoSlideshow;

internal sealed class PlaybackSurface : Control
{
    private Bitmap? image;
    private int revision;
    public int DrawnRevision { get; private set; } = -1;
    private int firstClick = -1;
    private int pressedRevision = -1;
    private int clicks;
    private bool held;
    private bool zoomed;
    private double zoom = 1;
    private PointF offset;
    private long lastEffect = -1;
    private bool removed;
    private bool fall;
    private RectangleF clockRect;
    private RectangleF indicatorRect;
    private readonly Font digitalFont = new("Segoe UI", 26, FontStyle.Bold);
    private readonly Font symbol = new("Segoe UI Symbol", 27, FontStyle.Bold);
    private string status = "";

    public PlaybackSurface()
    {
        DoubleBuffered = true;
        ResizeRedraw = true;
        SetStyle(ControlStyles.Selectable | ControlStyles.StandardDoubleClick, true);
        TabStop = true;
        BackColor = Color.Black;
    }

    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    internal Options Options { get; set; } = new();
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    internal Rectangle BarBounds { get; set; }
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    internal Action<int>? AddFavorite { get; set; }
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    internal Action<int>? MovePhoto { get; set; }
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    internal Action? Reveal { get; set; }
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    internal Action<int>? FrameDrawn { get; set; }
    public int ImageWidth => image?.Width ?? 0;
    public int ImageHeight => image?.Height ?? 0;
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    internal string Status { set { status = value; Invalidate(); } }
    public bool EffectActive => lastEffect >= 0;

    public void ShowFavoriteEffect(bool removal, bool falling)
    {
        lastEffect = Stopwatch.GetTimestamp();
        removed = removal;
        fall = falling;
        Invalidate();
    }

    public void SetPhoto(Bitmap? next, int generation)
    {
        var old = image;
        image = next;
        revision = generation;
        old?.Dispose();
        ResetZoom();
    }

    public void ResetZoom()
    {
        zoom = 1;
        offset = PointF.Empty;
        Invalidate();
    }

    private RectangleF PictureArea()
    {
        if (!Options.ReserveBarSpace) return ClientRectangle;
        int inset = Math.Clamp(BarBounds.Height + 38, 0, Math.Max(0, Height - 1));
        return new RectangleF(0, Options.BarAtTop ? inset : 0, Width, Math.Max(1, Height - inset));
    }

    private RectangleF ImageBounds(RectangleF area)
    {
        if (image is null) return RectangleF.Empty;
        float factor = (float)(zoom * Math.Min(area.Width / image.Width, area.Height / image.Height));
        var size = new SizeF(image.Width * factor, image.Height * factor);
        return new RectangleF(area.X + (area.Width - size.Width) / 2 + offset.X,
            area.Y + (area.Height - size.Height) / 2 + offset.Y, size.Width, size.Height);
    }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        base.OnMouseDown(e);
        if (e.Button != MouseButtons.Left) return;
        Focus();
        Capture = true;
        held = true;
        zoomed = false;
        pressedRevision = image != null && DrawnRevision == revision ? revision : -1;
        clicks = e.Clicks;
    }

    protected override void OnMouseUp(MouseEventArgs e)
    {
        base.OnMouseUp(e);
        if (e.Button != MouseButtons.Left) return;
        if (!held || zoomed || pressedRevision < 0 || pressedRevision != revision)
            firstClick = -1;
        else if (clicks == 1)
            firstClick = revision;
        else
        {
            if (clicks == 2 && firstClick == revision) AddFavorite?.Invoke(revision);
            firstClick = -1;
        }
        held = false;
        Capture = false;
    }

    protected override void OnMouseCaptureChanged(EventArgs e)
    {
        if (!Capture && held) { held = false; firstClick = -1; }
        base.OnMouseCaptureChanged(e);
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        Reveal?.Invoke();
        base.OnMouseMove(e);
    }

    protected override void OnMouseWheel(MouseEventArgs e)
    {
        if (e is HandledMouseEventArgs handled) handled.Handled = true;
        ApplyWheel(e.Delta, e.Location);
    }

    internal void ApplyWheel(int delta, Point location)
    {
        if (delta == 0) return;
        if (held || (MouseButtons & MouseButtons.Left) != 0)
        {
            zoomed = true;
            firstClick = -1;
            if (image is null) return;
            var area = PictureArea();
            var prior = ImageBounds(area);
            double next = Math.Clamp(zoom * Math.Pow(1.19, -delta / 120.0), 1, 8);
            float ratio = (float)(next / zoom);
            zoom = next;
            float x = location.X + (prior.X + prior.Width / 2 - location.X) * ratio - (area.X + area.Width / 2);
            float y = location.Y + (prior.Y + prior.Height / 2 - location.Y) * ratio - (area.Y + area.Height / 2);
            float limitX = Math.Max(0, (prior.Width * ratio - area.Width) / 2);
            float limitY = Math.Max(0, (prior.Height * ratio - area.Height) / 2);
            offset = zoom == 1 ? PointF.Empty : new(Math.Clamp(x, -limitX, limitX), Math.Clamp(y, -limitY, limitY));
            Invalidate();
        }
        else MovePhoto?.Invoke(delta < 0 ? 1 : -1);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        e.Graphics.Clear(Color.Black);
        var area = PictureArea();
        if (image is not null)
        {
            var state = e.Graphics.Save();
            e.Graphics.SetClip(area);
            e.Graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
            e.Graphics.DrawImage(image, ImageBounds(area));
            e.Graphics.Restore(state);
            if (DrawnRevision != revision)
            {
                DrawnRevision = revision;
                FrameDrawn?.Invoke(revision);
            }
        }
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        LayoutOverlays();
        if (Options.ClockVisible) DrawClock(e.Graphics);
        if (status.Length > 0)
        {
            var areaText = new Rectangle((Width - 360) / 2, 12, 360, 28);
            using var shade = new SolidBrush(Color.FromArgb(218, Color.Black));
            e.Graphics.FillRectangle(shade, areaText);
            TextRenderer.DrawText(e.Graphics, status, Font, areaText, Color.White,
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
        }
        if (lastEffect >= 0)
        {
            double time = Stopwatch.GetElapsedTime(lastEffect).TotalSeconds;
            if (time < 1.25) DrawEffect(e.Graphics, time);
            else lastEffect = -1;
        }
        base.OnPaint(e);
    }

    private void LayoutOverlays()
    {
        Size size = Options.AnalogClock ? new(76, 76) : new(144, 56);
        clockRect = new RectangleF(Options.ClockAtLeft ? 16 : Width - size.Width - 16, 16, size.Width, size.Height);
        if (clockRect.IntersectsWith(BarBounds)) clockRect.Y = BarBounds.Bottom + 12;
        indicatorRect = new RectangleF(Width - 75, 16, 56, 56);
        if (indicatorRect.IntersectsWith(BarBounds)) indicatorRect.Y = BarBounds.Bottom + 12;
        if (Options.ClockVisible && indicatorRect.IntersectsWith(clockRect)) indicatorRect.Y = clockRect.Bottom + 12;
    }

    private void DrawClock(Graphics graphics)
    {
        using var shade = new SolidBrush(Color.FromArgb(214, Color.Black));
        graphics.FillRoundedRectangle(shade, clockRect, new SizeF(12, 12));
        DateTime now = DateTime.Now;
        if (!Options.AnalogClock)
        {
            Center(graphics, now.ToString("HH:mm"), digitalFont, Brushes.White, clockRect);
            return;
        }
        var center = new PointF(clockRect.X + clockRect.Width / 2, clockRect.Y + clockRect.Height / 2);
        void Hand(double angle, float start, float end, float width, Color color)
        {
            using var pen = new Pen(color, width) { StartCap = LineCap.Round, EndCap = LineCap.Round };
            float x = (float)Math.Sin(angle);
            float y = -(float)Math.Cos(angle);
            graphics.DrawLine(pen, center.X + x * start, center.Y + y * start, center.X + x * end, center.Y + y * end);
        }
        for (int tick = 0; tick < 12; tick++) Hand(tick * Math.PI / 6, 28, 32, 2, Color.White);
        Hand((now.Hour % 12 + now.Minute / 60.0) * Math.PI / 6, 0, 17, 4, Color.White);
        Hand(now.Minute * Math.PI / 30, 0, 24, 3, Color.White);
        Hand(now.Second * Math.PI / 30, 0, 27, 1, Color.Gold);
    }

    private void DrawEffect(Graphics graphics, double time)
    {
        int alpha = (int)(255 * Math.Clamp((1.25 - time) / 0.5, 0, 1));
        using var shade = new SolidBrush(Color.FromArgb(alpha * 3 / 4, Color.Black));
        graphics.FillRoundedRectangle(shade, indicatorRect, new SizeF(12, 12));
        if (!removed)
        {
            using var glow = new SolidBrush(Color.FromArgb(alpha / 3, Color.Gold));
            for (int dx = -2; dx <= 2; dx++)
                for (int dy = -2; dy <= 2; dy++)
                    Center(graphics, "☆", symbol, glow, new RectangleF(indicatorRect.X + dx, indicatorRect.Y + dy,
                        indicatorRect.Width, indicatorRect.Height));
        }
        using var ink = new SolidBrush(Color.FromArgb(alpha, Color.White));
        Center(graphics, removed ? "☆×" : "☆", symbol, ink, indicatorRect);
        if (fall && time < 0.85)
        {
            var state = graphics.Save();
            float phase = (float)(time / 0.85);
            float y = BarBounds.Y + BarBounds.Height / 2;
            graphics.TranslateTransform(BarBounds.X + BarBounds.Width * 0.64f + 35 * phase,
                y + (Height - y + 60) * phase * phase);
            graphics.RotateTransform(phase * 105);
            Center(graphics, "★", symbol, Brushes.Gold, new RectangleF(-25, -25, 50, 50));
            graphics.Restore(state);
        }
    }

    private static void Center(Graphics graphics, string text, Font font, Brush brush, RectangleF area)
    {
        using var format = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
        graphics.DrawString(text, font, brush, area, format);
    }

    public static void Orient(Image image)
    {
        const int exifOrientation = 0x0112;
        if (!image.PropertyIdList.Contains(exifOrientation)) return;
        byte code = image.GetPropertyItem(exifOrientation)?.Value?.FirstOrDefault() ?? 1;
        var rotation = code switch
        {
            2 => RotateFlipType.RotateNoneFlipX, 3 => RotateFlipType.Rotate180FlipNone,
            4 => RotateFlipType.Rotate180FlipX, 5 => RotateFlipType.Rotate90FlipX,
            6 => RotateFlipType.Rotate90FlipNone, 7 => RotateFlipType.Rotate270FlipX,
            8 => RotateFlipType.Rotate270FlipNone, _ => RotateFlipType.RotateNoneFlipNone
        };
        if (rotation != RotateFlipType.RotateNoneFlipNone) image.RotateFlip(rotation);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            image?.Dispose();
            digitalFont.Dispose();
            symbol.Dispose();
        }
        base.Dispose(disposing);
    }
}
