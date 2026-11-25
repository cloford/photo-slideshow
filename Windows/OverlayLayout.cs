namespace PhotoSlideshow;

internal enum OverlayItem { Clock, Heart, Bar }

internal sealed record OverlayPosition(float X, float Y);
internal sealed record OverlayPlacement
{
    public OverlayPosition? Position { get; init; }
    public float Scale { get; init; } = 1;
    public bool UsePresetPosition { get; init; }
    [System.Text.Json.Serialization.JsonIgnore]
    public bool Custom => !UsePresetPosition && Position is not null;
}

internal readonly record struct OverlayFrames(RectangleF Safe, Options Options, float Dpi)
{
    public SizeF BaseSize(OverlayItem item)
    {
        var size = item switch
        {
            OverlayItem.Clock => new SizeF(144, 76),
            OverlayItem.Heart => new SizeF(56, 56),
            _ => new SizeF(510, 65)
        };
        float fit = Math.Min(Dpi, Math.Min(Safe.Width / 690, Safe.Height / 430));
        return new(size.Width * fit, size.Height * fit);
    }

    public float MaxScale(OverlayItem item)
    {
        var size = BaseSize(item);
        return Math.Max(0.55f, Math.Min(2, Math.Min(Safe.Width / size.Width, Safe.Height / size.Height)));
    }

    public RectangleF Clamp(RectangleF frame) =>
        new(Math.Min(Math.Max(Safe.Left, frame.Left), Safe.Right - frame.Width),
            Math.Min(Math.Max(Safe.Top, frame.Top), Safe.Bottom - frame.Height), frame.Width, frame.Height);

    public RectangleF Frame(OverlayItem item)
    {
        var size = BaseSize(item);
        var placement = Options.Placement(item);
        float scale = Math.Clamp(placement.Scale, 0.55f, MaxScale(item));
        float width = size.Width * scale;
        float height = size.Height * scale;
        if (placement.Custom && placement.Position is { } point)
            return new(Safe.Left + (Safe.Width - width) * Math.Clamp(point.X, 0, 1),
                Safe.Top + (Safe.Height - height) * Math.Clamp(point.Y, 0, 1), width, height);
        bool left = item == OverlayItem.Clock ? Options.ClockAtLeft : Options.NoticeAtLeft;
        float margin = item == OverlayItem.Bar ? 20 * size.Height / 65 : 16 * Dpi;
        float x = item == OverlayItem.Bar ? Safe.Left + (Safe.Width - width) / 2 :
            left ? Safe.Left + margin : Safe.Right - width - margin;
        float y = item == OverlayItem.Bar && !Options.BarAtTop ? Safe.Bottom - height - margin : Safe.Top + margin;
        return Clamp(new(x, y, width, height));
    }

    public OverlayPlacement Placement(RectangleF frame, float scale)
    {
        frame = Clamp(frame);
        return new()
        {
            Position = new(Safe.Width > frame.Width ? (frame.Left - Safe.Left) / (Safe.Width - frame.Width) : 0,
                Safe.Height > frame.Height ? (frame.Top - Safe.Top) / (Safe.Height - frame.Height) : 0),
            Scale = scale
        };
    }

    private RectangleF Avoid(RectangleF obstacle, RectangleF frame)
    {
        float margin = 10 * Dpi;
        if (!frame.IntersectsWith(RectangleF.Inflate(obstacle, margin, margin))) return frame;
        RectangleF[] candidates =
        [
            new(frame.Left, obstacle.Bottom + margin, frame.Width, frame.Height),
            new(frame.Left, obstacle.Top - margin - frame.Height, frame.Width, frame.Height),
            new(obstacle.Left - margin - frame.Width, frame.Top, frame.Width, frame.Height),
            new(obstacle.Right + margin, frame.Top, frame.Width, frame.Height)
        ];
        var safe = Safe;
        return candidates.Where(safe.Contains).OrderBy(rect =>
            MathF.Pow(rect.Left - frame.Left, 2) + MathF.Pow(rect.Top - frame.Top, 2)).FirstOrDefault(frame);
    }

    public (RectangleF Clock, RectangleF Heart) Overlays(bool editing)
    {
        var clock = Frame(OverlayItem.Clock);
        var heart = Frame(OverlayItem.Heart);
        if (editing) return (clock, heart);
        var bar = Frame(OverlayItem.Bar);
        clock = Avoid(bar, clock);
        heart = Avoid(bar, heart);
        float gap = 10 * Dpi;
        if (Options.ClockVisible && (heart.IntersectsWith(RectangleF.Inflate(clock, gap, gap)) ||
            Frame(OverlayItem.Heart).IntersectsWith(RectangleF.Inflate(Frame(OverlayItem.Clock), gap, gap))))
        {
            float y = clock.Bottom + gap;
            float shift = Math.Max(0, y + heart.Height - Safe.Bottom);
            clock.Y -= shift;
            heart.Y = y - shift;
            var group = RectangleF.Union(clock, heart);
            var moved = Avoid(bar, group);
            clock.Offset(moved.X - group.X, moved.Y - group.Y);
            heart.Offset(moved.X - group.X, moved.Y - group.Y);
        }
        return (clock, heart);
    }

    public RectangleF PictureArea(float aspect)
    {
        if (!Options.ReserveBarSpace) return Safe;
        var bar = RectangleF.Intersect(Safe, RectangleF.Inflate(Frame(OverlayItem.Bar), 12 * Dpi, 12 * Dpi));
        RectangleF[] candidates =
        [
            new(Safe.Left, Safe.Top, Safe.Width, bar.Top - Safe.Top),
            new(Safe.Left, bar.Bottom, Safe.Width, Safe.Bottom - bar.Bottom),
            new(Safe.Left, Safe.Top, bar.Left - Safe.Left, Safe.Height),
            new(bar.Right, Safe.Top, Safe.Right - bar.Right, Safe.Height)
        ];
        return candidates.MaxBy(rect => Math.Min(rect.Width / aspect, rect.Height));
    }
}
