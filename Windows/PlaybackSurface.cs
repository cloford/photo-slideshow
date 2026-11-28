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
    private long barEffectStarted = -1;
    private bool subtle;
    private bool removed;
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    internal bool IsFavorite { get; set; }
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    internal bool Editing { get; set; }
    private bool fall;
    private bool bounce;
    internal PointF FavoriteOrigin;
    private RectangleF clockRect;
    private RectangleF indicatorRect;
    private readonly Font digitalFont = new("Segoe UI", 34, FontStyle.Bold, GraphicsUnit.Pixel);
    private readonly Font symbol = new("Segoe UI Symbol", 37, FontStyle.Bold, GraphicsUnit.Pixel);
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
    internal Action? ZoomChanged { get; set; }
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    internal Action<int>? FrameDrawn { get; set; }
    public int ImageWidth => image?.Width ?? 0;
    public int ImageHeight => image?.Height ?? 0;
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    internal string Status { set { status = value; Invalidate(); } }
    public bool EffectActive => lastEffect >= 0 || barEffectStarted >= 0;
    internal OverlayFrames Geometry => new(new RectangleF(0, 0, Math.Max(1, Width), Math.Max(1, Height)),
        Options, DeviceDpi / 96f);

    internal Bitmap? CopyImage() => image is null ? null : new Bitmap(image);

    public void ShowFavoriteEffect(bool removal, bool falling, bool bouncing)
    {
        lastEffect = Stopwatch.GetTimestamp();
        removed = removal;
        subtle = false;
        fall = falling;
        bounce = bouncing;
        barEffectStarted = falling || bouncing ? lastEffect : -1;
        Invalidate();
    }

    public void PulseFavorite()
    {
        lastEffect = Stopwatch.GetTimestamp();
        removed = false;
        subtle = true;
        Invalidate();
    }

    public void SetPhoto(Bitmap? next, int generation)
    {
        var old = image;
        image = next;
        revision = generation;
        if (!removed) lastEffect = -1;
        barEffectStarted = -1;
        bounce = fall = false;
        old?.Dispose();
        ResetZoom();
    }

    public void ResetZoom()
    {
        zoom = 1;
        offset = PointF.Empty;
        Invalidate();
    }

    private RectangleF PictureArea() =>
        Geometry.PictureArea(image is null ? 16f / 9 : (float)image.Width / image.Height);

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
        if (e.Button != MouseButtons.Left || Editing) return;
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
        if (e.Button != MouseButtons.Left || Editing) return;
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
        base.OnMouseMove(e);
    }

    protected override void OnMouseWheel(MouseEventArgs e)
    {
        if (e is HandledMouseEventArgs handled) handled.Handled = true;
        ApplyWheel(e.Delta, e.Location);
    }

    internal void ApplyWheel(int delta, Point location)
    {
        if (delta == 0 || Editing) return;
        if (held || (MouseButtons & MouseButtons.Left) != 0)
        {
            zoomed = true;
            firstClick = -1;
            if (image is null) return;
            var area = PictureArea();
            var prior = ImageBounds(area);
            double next = Math.Clamp(zoom * Math.Pow(1.19, -delta / 120.0), 1, 8);
            if (next == zoom) return;
            float ratio = (float)(next / zoom);
            zoom = next;
            float x = location.X + (prior.X + prior.Width / 2 - location.X) * ratio - (area.X + area.Width / 2);
            float y = location.Y + (prior.Y + prior.Height / 2 - location.Y) * ratio - (area.Y + area.Height / 2);
            float limitX = Math.Max(0, (prior.Width * ratio - area.Width) / 2);
            float limitY = Math.Max(0, (prior.Height * ratio - area.Height) / 2);
            offset = zoom == 1 ? PointF.Empty : new(Math.Clamp(x, -limitX, limitX), Math.Clamp(y, -limitY, limitY));
            Invalidate();
            ZoomChanged?.Invoke();
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
        if (Options.ClockVisible || Editing) DrawClock(e.Graphics);
        if (status.Length > 0)
        {
            var areaText = new Rectangle((Width - 360) / 2, 12, 360, 28);
            using var shade = new SolidBrush(Color.FromArgb(218, Color.Black));
            e.Graphics.FillRectangle(shade, areaText);
            TextRenderer.DrawText(e.Graphics, status, Font, areaText, Color.White,
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
        }
        double elapsed = lastEffect >= 0 ? Stopwatch.GetElapsedTime(lastEffect).TotalSeconds : double.PositiveInfinity;
        if (elapsed >= (subtle ? 0.36 : 1.25)) lastEffect = -1;
        if (Editing) DrawHeart(e.Graphics, "♡", Color.Silver, 255);
        else
        {
            if (image is not null && IsFavorite)
            {
                double glow = lastEffect < 0 || removed ? 0
                    : subtle ? 0.60 * Math.Clamp((0.36 - elapsed) / 0.27, 0, 1)
                    : Math.Clamp((1.05 - elapsed) / 0.45, 0, 1);
                DrawHeart(e.Graphics, "♥", Color.HotPink, 255, glow);
            }
            if (lastEffect >= 0 && removed)
                DrawHeart(e.Graphics, "♡", Color.White, (int)(255 * Math.Clamp((1.25 - elapsed) / 0.5, 0, 1)));
            if (barEffectStarted >= 0)
            {
                double barElapsed = Stopwatch.GetElapsedTime(barEffectStarted).TotalSeconds;
                if (barElapsed < (fall ? 0.85 : 0.46)) DrawBarEffect(e.Graphics, barElapsed);
                else barEffectStarted = -1;
            }
        }
        base.OnPaint(e);
    }

    private void LayoutOverlays() =>
        (clockRect, indicatorRect) = Geometry.Overlays(Editing);

    private void DrawClock(Graphics graphics)
    {
        var state = graphics.Save();
        graphics.TranslateTransform(clockRect.X, clockRect.Y);
        graphics.ScaleTransform(clockRect.Width / 144, clockRect.Height / 76);
        var area = new RectangleF(0, 0, 144, 76);
        using var shade = new SolidBrush(Color.FromArgb(214, Color.Black));
        graphics.FillRoundedRectangle(shade, area, new SizeF(12, 12));
        DateTime now = DateTime.Now;
        if (!Options.AnalogClock)
        {
            Center(graphics, now.ToString("HH:mm"), digitalFont, Brushes.White, area);
            graphics.Restore(state);
            return;
        }
        var center = new PointF(72, 38);
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
        graphics.Restore(state);
    }

    private void DrawHeart(Graphics graphics, string glyph, Color color, int alpha, double glow = 0)
    {
        var state = graphics.Save();
        graphics.TranslateTransform(indicatorRect.X, indicatorRect.Y);
        graphics.ScaleTransform(indicatorRect.Width / 56, indicatorRect.Height / 56);
        var area = new RectangleF(0, 0, 56, 56);
        using var shade = new SolidBrush(Color.FromArgb(alpha * 3 / 4, Color.Black));
        graphics.FillRoundedRectangle(shade, area, new SizeF(12, 12));
        if (glow > 0)
        {
            using var halo = new SolidBrush(Color.FromArgb((int)(100 * glow), Color.HotPink));
            for (int dx = -2; dx <= 2; dx++)
                for (int dy = -2; dy <= 2; dy++)
                    Center(graphics, glyph, symbol, halo, new RectangleF(dx, dy, 56, 56));
        }
        using var ink = new SolidBrush(Color.FromArgb(alpha, color));
        Center(graphics, glyph, symbol, ink, area);
        if (removed && glyph == "♡" && !Editing)
        {
            using var mark = new SolidBrush(Color.FromArgb(alpha, Color.LightCoral));
            using var font = new Font("Segoe UI", 18, FontStyle.Bold, GraphicsUnit.Pixel);
            graphics.FillEllipse(shade, 33, 30, 19, 19);
            Center(graphics, "×", font, mark, new RectangleF(33, 30, 19, 19));
        }
        graphics.Restore(state);
    }

    private void DrawBarEffect(Graphics graphics, double time)
    {
        if (bounce && time < 0.46)
        {
            var state = graphics.Save();
            float wave = MathF.Sin((float)(time / 0.46 * Math.PI));
            float scale = BarBounds.Width / 510f;
            graphics.TranslateTransform(FavoriteOrigin.X,
                FavoriteOrigin.Y + (BarBounds.Top + BarBounds.Height / 2f < Height / 2f ? 36 : -36) * wave * scale);
            graphics.ScaleTransform(scale, scale);
            float size = 42 + 8 * wave;
            Center(graphics, "♥", symbol, Brushes.HotPink, new RectangleF(-size / 2, -size / 2, size, size));
            graphics.Restore(state);
        }
        if (fall && time < 0.85)
        {
            var state = graphics.Save();
            float phase = (float)(time / 0.85);
            float y = FavoriteOrigin.Y;
            graphics.TranslateTransform(FavoriteOrigin.X + 35 * phase,
                y + (Height - y + 60) * phase * phase);
            graphics.RotateTransform(phase * 105);
            float scale = BarBounds.Width / 510f;
            graphics.ScaleTransform(scale, scale);
            Center(graphics, "♥", symbol, Brushes.HotPink, new RectangleF(-25, -25, 50, 50));
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
